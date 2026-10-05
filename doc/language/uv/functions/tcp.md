# tcp API reference

Complete public example: [dns_tcp](../examples/dns_tcp.titan). See the
[example guide](../examples/README.md) for build/run commands and platform conditions.

The signatures use ordinary public `titan.uv` types. Read the [ownership contracts](../CONTRACT-NOTES.md) before submitting native work. Status values and callback results remain distinct.

## socketpair

`uv_socketpair` — **canonical exported function**

Create a connected pair of native sockets. Returns status and two owning socket tokens on success; adopt or close each endpoint explicitly.

```titan
function socketpair(kind: integer, protocol: integer, flags0: integer, flags1: integer): (integer, os_sock_t?, os_sock_t?)
```

**Inputs and outputs:** kind: INPUT integer value; checked native narrowing occurs before native ownership is accepted.; protocol: INPUT integer value; checked native narrowing occurs before native ownership is accepted.; flags0: INPUT integer value; checked native narrowing occurs before native ownership is accepted.; flags1: INPUT integer value; checked native narrowing occurs before native ownership is accepted.

**Result, lifetime and cleanup:** Return type: (integer, os_sock_t?, os_sock_t?). Synchronous. Success returns status 0 and two separately owned native socket tokens; failure returns status and nil tokens. Per-end NONBLOCK flags select creation behavior. This operation needs no initialized TCP handle. Transfer each socket to an appropriate handle or close it exactly once; Windows SOCKET is distinct from a CRT file descriptor.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L514).


## tcp_bind

`uv_tcp_bind` — **canonical exported function**

Bind TCP to the typed local address. Port zero requests an OS-selected port; `tcp_getsockname` can retrieve the bound address.

```titan
function tcp_bind(handle: tcp_t, addr: sockaddr_t, flags: integer): integer
```

**Inputs and outputs:** handle: INPUT/OUTPUT initialized tcp_t owner/view; mutations preserve its single owner and reserved native data slot; close completion ends native handle lifetime.; addr: INPUT complete typed address owner; no sockaddr pointer/header required; constructor/accessors encode family/port/bytes. Native submission consumes or copies address during the call.; flags: INPUT integer value; checked native narrowing occurs before native ownership is accepted.

**Result, lifetime and cleanup:** Return type: integer. Requires an initialized TCP handle. Native kernel support is separate from compiled API availability.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L643).


## tcp_close_reset

`uv_tcp_close_reset` — **canonical exported function**

Close TCP with a reset and an optional close callback. A successful call starts close ownership; do not also submit ordinary close for the same lifetime.

```titan
function tcp_close_reset(handle: tcp_t, callback: (function (handle_t): ())?): integer
```

**Inputs and outputs:** handle: INPUT/OUTPUT initialized tcp_t owner/view; mutations preserve its single owner and reserved native data slot; close completion ends native handle lifetime.; callback: INPUT ordinary callable, retained until the promised callback interval ends; callback argument owners are borrowed views retained through callback return. Optional nil is meaningful; see contract.

**Result, lifetime and cleanup:** Return type: integer. Requires an initialized TCP handle. Native kernel support is separate from compiled API availability. RST close accepts only on status 0; must not mix with shutdown; on error handle remains open. Close callback retires owner.

**Callbacks:** deferred-once-on-success. the owning main Lua thread; timing is specified above

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L652).


## tcp_connect

`uv_tcp_connect` — **canonical exported function**

Submit a connection attempt to a typed peer address. Immediate rejection has no callback; accepted completion reports status through the connect callback.

```titan
function tcp_connect(req: connect_t, handle: tcp_t, addr: sockaddr_t, callback: connect_cb): integer
```

**Inputs and outputs:** req: INPUT/OUTPUT allocated nonpending request owner; accepted submission retains owner until its terminal callback returns; rejection owes no async callback.; handle: INPUT/OUTPUT initialized tcp_t owner/view; mutations preserve its single owner and reserved native data slot; close completion ends native handle lifetime.; addr: INPUT complete typed address owner; no sockaddr pointer/header required; constructor/accessors encode family/port/bytes. Native submission consumes or copies address during the call.; callback: INPUT ordinary callable, retained until the promised callback interval ends; callback argument owners are borrowed views retained through callback return.

**Result, lifetime and cleanup:** Return type: integer. Requires an initialized TCP handle. Native kernel support is separate from compiled API availability. Initialized TCP; fresh reusable completed connect request; address copied during submission. Negative return no callback. Accepted request and handle survive callback.

**Callbacks:** deferred-once-on-success. the owning main Lua thread; timing is specified above

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L653).


## tcp_getpeername

`uv_tcp_getpeername` — **canonical exported function**

Return `(status, copied_peer_address?, native_length)` for the connected peer. The address copy survives later handle changes/close.

```titan
function tcp_getpeername(handle: tcp_t): (integer, sockaddr_t?, integer)
```

**Inputs and outputs:** handle: INPUT/OUTPUT initialized tcp_t owner/view; mutations preserve its single owner and reserved native data slot; close completion ends native handle lifetime.

**Result, lifetime and cleanup:** Return type: (integer, sockaddr_t?, integer). Requires a live concrete handle. Synchronous success returns 0, a copied sockaddr_t, and the native address length; failure returns status, nil, and the native length output. Storage capacity is internal. Retaining the copied address after handle close is valid.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L649).


## tcp_getsockname

`uv_tcp_getsockname` — **canonical exported function**

Return `(status, copied_local_address?, native_length)` for the socket's bound endpoint. The address copy survives later handle changes/close.

```titan
function tcp_getsockname(handle: tcp_t): (integer, sockaddr_t?, integer)
```

**Inputs and outputs:** handle: INPUT/OUTPUT initialized tcp_t owner/view; mutations preserve its single owner and reserved native data slot; close completion ends native handle lifetime.

**Result, lifetime and cleanup:** Return type: (integer, sockaddr_t?, integer). Requires a live concrete handle. Synchronous success returns 0, a copied sockaddr_t, and the native address length; failure returns status, nil, and the native length output. Storage capacity is internal. Retaining the copied address after handle close is valid.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L646).


## tcp_init

`uv_tcp_init` — **canonical exported function**

Initialize a TCP owner; native socket creation may be deferred until bind, connect, or adoption.

```titan
function tcp_init(loop: loop_t, handle: tcp_t): integer
```

**Inputs and outputs:** loop: INPUT initialized owning loop; accepted handles/requests retain it through retirement.; handle: INPUT/OUTPUT final tcp_t owner in fresh or retired state, before this native initialization; successful initialization establishes a close obligation. Follow the explicit rejection rule for this operation.

**Result, lifetime and cleanup:** Return type: integer. Requires an initialized loop and a concrete owner in fresh or retired state; an uninitialized loop or currently initialized/closing handle returns EINVAL. Successful initialization establishes the native lifetime and close obligation, even if no event is ever started. Uses the native AF_UNSPEC default. Bind, connect or open establishes the socket connection/resource separately. A rejected initialization establishes no new native lifetime.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L613).


## tcp_init_ex

`uv_tcp_init_ex` — **canonical exported function**

Initialize TCP with native family-selection flags. Unsupported flags/families return native status.

```titan
function tcp_init_ex(loop: loop_t, handle: tcp_t, flags: integer): integer
```

**Inputs and outputs:** loop: INPUT initialized owning loop; accepted handles/requests retain it through retirement.; handle: INPUT/OUTPUT final tcp_t owner in fresh or retired state, before this native initialization; successful initialization establishes a close obligation. Follow the explicit rejection rule for this operation.; flags: INPUT integer value; checked native narrowing occurs before native ownership is accepted.

**Result, lifetime and cleanup:** Return type: integer. Requires an initialized loop and a concrete owner in fresh or retired state; an uninitialized loop or currently initialized/closing handle returns EINVAL. Successful initialization establishes the native lifetime and close obligation, even if no event is ever started. Flags select native family/creation policy. Checked narrowing precedes acceptance; native status preserves platform support. A rejected initialization establishes no new native lifetime.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L614).


## tcp_keepalive

`uv_tcp_keepalive` — **canonical exported function**

Enable/disable TCP keepalive and set its idle delay in seconds.

```titan
function tcp_keepalive(handle: tcp_t, enable: integer, delay: integer): integer
```

**Inputs and outputs:** handle: INPUT/OUTPUT initialized tcp_t owner/view; mutations preserve its single owner and reserved native data slot; close completion ends native handle lifetime.; enable: INPUT integer value; checked native narrowing occurs before native ownership is accepted.; delay: INPUT integer value; checked native narrowing occurs before native ownership is accepted.

**Result, lifetime and cleanup:** Return type: integer. Requires an initialized TCP handle. Native kernel support is separate from compiled API availability.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L617).


## tcp_keepalive_ex

`uv_tcp_keepalive_ex` — **canonical exported function**

Configure TCP keepalive with idle seconds, interval seconds, and probe count when enabled.

```titan
function tcp_keepalive_ex(handle: tcp_t, on: integer, idle: integer, intvl: integer, count: integer): integer
```

**Inputs and outputs:** handle: INPUT/OUTPUT initialized tcp_t owner/view; mutations preserve its single owner and reserved native data slot; close completion ends native handle lifetime.; on: INPUT integer value; checked native narrowing occurs before native ownership is accepted.; idle: INPUT integer value; checked native narrowing occurs before native ownership is accepted.; intvl: INPUT integer value; checked native narrowing occurs before native ownership is accepted.; count: INPUT integer value; checked native narrowing occurs before native ownership is accepted.

**Result, lifetime and cleanup:** Return type: integer. Requires an initialized TCP handle. Native kernel support is separate from compiled API availability. idle/intvl seconds and cnt probes must be >=1; new1.52.0; older keepalive fixed intvl/cnt behavior is not silent emulation.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L620).


## tcp_nodelay

`uv_tcp_nodelay` — **canonical exported function**

Enable or disable TCP_NODELAY, controlling Nagle's algorithm; a nonzero enable value selects the native enabled state.

```titan
function tcp_nodelay(handle: tcp_t, enable: integer): integer
```

**Inputs and outputs:** handle: INPUT/OUTPUT initialized tcp_t owner/view; mutations preserve its single owner and reserved native data slot; close completion ends native handle lifetime.; enable: INPUT integer value; checked native narrowing occurs before native ownership is accepted.

**Result, lifetime and cleanup:** Return type: integer. Requires an initialized TCP handle. Native kernel support is separate from compiled API availability.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L616).


## tcp_open

`uv_tcp_open` — **canonical exported function**

Adopt an existing native socket into this TCP owner. On successful adoption the handle's close lifetime owns the socket.

```titan
function tcp_open(handle: tcp_t, socket: os_sock_t): integer
```

**Inputs and outputs:** handle: INPUT/OUTPUT initialized tcp_t owner/view; mutations preserve its single owner and reserved native data slot; close completion ends native handle lifetime.; socket: INPUT exact-width borrowed native identifier token; collecting the token never closes/adopts its resource; see this operation's transfer rule.

**Result, lifetime and cleanup:** Return type: integer. Requires an initialized live TCP handle. Status 0 transfers ownership of the supplied native socket to that handle; later handle close closes it. Rejection leaves the socket with the caller. The os_sock_t token preserves native socket width.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L615).


## tcp_simultaneous_accepts

`uv_tcp_simultaneous_accepts` — **canonical exported function**

Enable or disable native simultaneous accept behavior. Platform behavior remains libuv's contract.

```titan
function tcp_simultaneous_accepts(handle: tcp_t, enable: integer): integer
```

**Inputs and outputs:** handle: INPUT/OUTPUT initialized tcp_t owner/view; mutations preserve its single owner and reserved native data slot; close completion ends native handle lifetime.; enable: INPUT integer value; checked native narrowing occurs before native ownership is accepted.

**Result, lifetime and cleanup:** Return type: integer. Requires an initialized TCP handle. Native kernel support is separate from compiled API availability.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L625).

