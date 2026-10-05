# udp API reference

Complete public example: [udp_loopback](../examples/udp_loopback.titan). See the
[example guide](../examples/README.md) for build/run commands and platform conditions.

UDP has handle_t but no stream_t inheritance. Send requests retain vector snapshots through their one completion; request reuse inside that callback is supported. Receive allocation returns writable storage. An empty datagram has a peer address and count zero; an idle no-data callback may have no peer. MMSG_CHUNK slices retain the whole original allocation; MMSG_FREE retires it. recv_stop inside a CHUNK may suppress native FREE, so retain until a later allocation or close. cancel does not cancel UDP sends. udp_send rejects an empty vector before native acceptance; use one zero-length buf_t for an empty datagram. udp_try_send rejects an empty vector. udp_try_send2 rejects an empty outer batch but retains native platform differences for an empty inner vector (Linux can send it; Windows returns EINVAL).

## udp_bind

`uv_udp_bind` — **canonical exported function**

Bind a UDP handle to a typed local address with the requested binding flags.

```titan
function udp_bind(handle: udp_t, address: sockaddr_t, flags: integer): integer
```

**Inputs and outputs:** handle: INPUT/OUTPUT initialized udp_t owner/view; mutations preserve its single owner and reserved native data slot; close completion ends native handle lifetime.; address: INPUT complete typed address owner; no sockaddr pointer/header required; constructor/accessors encode family/port/bytes. Native submission consumes or copies address during the call.; flags: INPUT integer value; checked native narrowing occurs before native ownership is accepted.

**Result, lifetime and cleanup:** Return type: integer. Requires initialized UDP handle; address/buffer metadata borrowed or copied at call; async bytes retained through callback. Flags combine; connected address NULL semantics intentional.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L766).


## udp_connect

`uv_udp_connect` — **canonical exported function**

Set a default UDP peer; nil disconnects that peer according to native semantics. This does not perform a TCP-style connection handshake.

```titan
function udp_connect(handle: udp_t, address: sockaddr_t?): integer
```

**Inputs and outputs:** handle: INPUT/OUTPUT initialized udp_t owner/view; mutations preserve its single owner and reserved native data slot; close completion ends native handle lifetime.; address: INPUT complete typed address owner; no sockaddr pointer/header required; constructor/accessors encode family/port/bytes. Native submission consumes or copies address during the call. Optional nil is meaningful; see contract.

**Result, lifetime and cleanup:** Return type: integer. Requires initialized UDP handle; address/buffer metadata borrowed or copied at call; async bytes retained through callback. Flags combine; connected address NULL semantics intentional.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L769).


## udp_get_send_queue_count

`uv_udp_get_send_queue_count` — **canonical exported function**

Return requests currently queued for UDP sending.

```titan
function udp_get_send_queue_count(handle: udp_t): integer
```

**Inputs and outputs:** handle: INPUT/OUTPUT initialized udp_t owner/view; mutations preserve its single owner and reserved native data slot; close completion ends native handle lifetime.

**Result, lifetime and cleanup:** Return type: integer. Requires initialized UDP handle; address/buffer metadata borrowed or copied at call; async bytes retained through callback. Flags combine; connected address NULL semantics intentional.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L814).


## udp_get_send_queue_size

`uv_udp_get_send_queue_size` — **canonical exported function**

Return bytes currently queued for UDP sending.

```titan
function udp_get_send_queue_size(handle: udp_t): integer
```

**Inputs and outputs:** handle: INPUT/OUTPUT initialized udp_t owner/view; mutations preserve its single owner and reserved native data slot; close completion ends native handle lifetime.

**Result, lifetime and cleanup:** Return type: integer. Requires initialized UDP handle; address/buffer metadata borrowed or copied at call; async bytes retained through callback. Flags combine; connected address NULL semantics intentional.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L813).


## udp_getpeername

`uv_udp_getpeername` — **canonical exported function**

Return `(status, copied_peer_address?, native_length)` for the connected peer. The address copy survives later handle changes/close.

```titan
function udp_getpeername(handle: udp_t): (integer, sockaddr_t?, integer)
```

**Inputs and outputs:** handle: INPUT/OUTPUT initialized udp_t owner/view; mutations preserve its single owner and reserved native data slot; close completion ends native handle lifetime.

**Result, lifetime and cleanup:** Return type: (integer, sockaddr_t?, integer). Requires a live concrete handle. Synchronous success returns 0, a copied sockaddr_t, and the native address length; failure returns status, nil, and the native length output. Storage capacity is internal. Retaining the copied address after handle close is valid.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L771).


## udp_getsockname

`uv_udp_getsockname` — **canonical exported function**

Return `(status, copied_local_address?, native_length)` for the socket's bound endpoint. The address copy survives later handle changes/close.

```titan
function udp_getsockname(handle: udp_t): (integer, sockaddr_t?, integer)
```

**Inputs and outputs:** handle: INPUT/OUTPUT initialized udp_t owner/view; mutations preserve its single owner and reserved native data slot; close completion ends native handle lifetime.

**Result, lifetime and cleanup:** Return type: (integer, sockaddr_t?, integer). Requires a live concrete handle. Synchronous success returns 0, a copied sockaddr_t, and the native address length; failure returns status, nil, and the native length output. Storage capacity is internal. Retaining the copied address after handle close is valid.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L774).


## udp_init

`uv_udp_init` — **canonical exported function**

Initialize a UDP handle; bind/connect/send can later create or select its socket.

```titan
function udp_init(loop: loop_t, handle: udp_t): integer
```

**Inputs and outputs:** loop: INPUT initialized owning loop; accepted handles/requests retain it through retirement.; handle: INPUT/OUTPUT final udp_t owner in fresh or retired state, before this native initialization; successful initialization establishes a close obligation. Follow the explicit rejection rule for this operation.

**Result, lifetime and cleanup:** Return type: integer. Requires an initialized loop and a concrete owner in fresh or retired state; an uninitialized loop or currently initialized/closing handle returns EINVAL. Successful initialization establishes the native lifetime and close obligation, even if no event is ever started. Uses zero native initialization flags. Bind, connect or open establishes a socket resource separately. A rejected initialization establishes no new native lifetime.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L760).


## udp_init_ex

`uv_udp_init_ex` — **canonical exported function**

Initialize UDP with native family/receive-mode flags, including recvmmsg where supported.

```titan
function udp_init_ex(loop: loop_t, handle: udp_t, flags: integer): integer
```

**Inputs and outputs:** loop: INPUT initialized owning loop; accepted handles/requests retain it through retirement.; handle: INPUT/OUTPUT final udp_t owner in fresh or retired state, before this native initialization; successful initialization establishes a close obligation. Follow the explicit rejection rule for this operation.; flags: INPUT integer value; checked native narrowing occurs before native ownership is accepted.

**Result, lifetime and cleanup:** Return type: integer. Requires an initialized loop and a concrete owner in fresh or retired state; an uninitialized loop or currently initialized/closing handle returns EINVAL. Successful initialization establishes the native lifetime and close obligation, even if no event is ever started. Flags select native family/receive policy; checked narrowing precedes acceptance. A rejected initialization establishes no new native lifetime.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L761).


## udp_open

`uv_udp_open` — **canonical exported function**

Adopt an existing socket into a UDP handle. Successful adoption gives the handle responsibility for closing it.

```titan
function udp_open(handle: udp_t, socket: os_sock_t): integer
```

**Inputs and outputs:** handle: INPUT/OUTPUT initialized udp_t owner/view; mutations preserve its single owner and reserved native data slot; close completion ends native handle lifetime.; socket: INPUT exact-width borrowed native identifier token; collecting the token never closes/adopts its resource; see this operation's transfer rule.

**Result, lifetime and cleanup:** Return type: integer. Requires initialized UDP handle; address/buffer metadata borrowed or copied at call; async bytes retained through callback. Flags combine; connected address NULL semantics intentional.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L762).


## udp_open_ex

`uv_udp_open_ex` — **canonical exported function**

Adopt an existing UDP socket with the explicit native adoption flags.

```titan
function udp_open_ex(handle: udp_t, socket: os_sock_t, flags: integer): integer
```

**Inputs and outputs:** handle: INPUT/OUTPUT initialized udp_t owner/view; mutations preserve its single owner and reserved native data slot; close completion ends native handle lifetime.; socket: INPUT exact-width borrowed native identifier token; collecting the token never closes/adopts its resource; see this operation's transfer rule.; flags: INPUT integer value; checked native narrowing occurs before native ownership is accepted.

**Result, lifetime and cleanup:** Return type: integer. Requires initialized UDP handle; address/buffer metadata borrowed or copied at call; async bytes retained through callback. Flags combine; connected address NULL semantics intentional.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L763).


## udp_recv_start

`uv_udp_recv_start` — **canonical exported function**

Start datagram reception with writable allocation and receive callbacks. Distinguish a zero-byte datagram with a peer from a no-data callback; inspect PARTIAL and recvmmsg flags.

```titan
function udp_recv_start(handle: udp_t, alloc_callback: function (handle_t, integer): (buf_t), recv_callback: function (udp_t, integer, buf_t?, sockaddr_t?, integer): ()): integer
```

**Inputs and outputs:** handle: INPUT/OUTPUT initialized udp_t owner/view; mutations preserve its single owner and reserved native data slot; close completion ends native handle lifetime.; alloc_callback: INPUT ordinary callable, retained until the promised callback interval ends; callback argument owners are borrowed views retained through callback return.; recv_callback: INPUT ordinary callable, retained until the promised callback interval ends; callback argument owners are borrowed views retained through callback return.

**Result, lifetime and cleanup:** Return type: integer. Requires initialized UDP handle; address/buffer metadata borrowed or copied at call; async bytes retained through callback. Flags combine; connected address NULL semantics intentional. Allocation and recv callbacks run loop-thread. nread 0 with addr NULL means no data; nread 0 with addr non-NULL is empty datagram. MMSG_CHUNK shares a retained allocation; MMSG_FREE ends the native batch borrow. Saved buf_t views still retain their backing allocation after callback return. The address argument is a copied sockaddr_t, not a borrowed native pointer.

With UDP_RECVMMSG enabled, allocation callbacks must return buffers whose lengths are positive multiples of 64 KiB.

**Callbacks:** persistent-alloc-recv. the owning main Lua thread; timing is specified above

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L808).


## udp_recv_stop

`uv_udp_recv_stop` — **canonical exported function**

Stop native reception without closing the socket. Retained recvmmsg chunks continue to own their allocation until their documented retirement.

```titan
function udp_recv_stop(handle: udp_t): integer
```

**Inputs and outputs:** handle: INPUT/OUTPUT initialized udp_t owner/view; mutations preserve its single owner and reserved native data slot; close completion ends native handle lifetime.

**Result, lifetime and cleanup:** Return type: integer. Requires initialized UDP handle; address/buffer metadata borrowed or copied at call; async bytes retained through callback. Flags combine; connected address NULL semantics intentional.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L812).


## udp_send

`uv_udp_send` — **canonical exported function**

Submit one datagram from a nonempty buffer vector. A nil destination uses the connected peer. Accepted submission retains every buffer owner through the send callback.

```titan
function udp_send(request: udp_send_t, handle: udp_t, buffers: {buf_t}, address: sockaddr_t?, callback: (function (udp_send_t, integer): ())?): integer
```

**Inputs and outputs:** request: INPUT/OUTPUT allocated nonpending request owner; accepted submission retains owner until its terminal callback returns; rejection owes no async callback.; handle: INPUT/OUTPUT initialized udp_t owner/view; mutations preserve its single owner and reserved native data slot; close completion ends native handle lifetime.; buffers: INPUT byte owner or vector; immutable strings are valid only for input; async submission snapshots descriptors and retains owners, so Array edits cannot alter accepted I/O; do not mutate borrowed byte contents before completion.; address: INPUT complete typed address owner; no sockaddr pointer/header required; constructor/accessors encode family/port/bytes. Native submission consumes or copies address during the call. Optional nil is meaningful; see contract.; callback: INPUT ordinary callable, retained until the promised callback interval ends; callback argument owners are borrowed views retained through callback return. Optional nil is meaningful; see contract.

**Result, lifetime and cleanup:** Return type: integer. Requires initialized UDP handle; address/buffer metadata borrowed or copied at call; async bytes retained through callback. Flags combine; connected address NULL semantics intentional. Retain writable/readable byte owners until callback; native vector/address are copied as needed. Connected destination requires addr NULL. No uv_cancel support.

**Callbacks:** deferred-once-on-success. the owning main Lua thread; timing is specified above

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L792).


## udp_set_broadcast

`uv_udp_set_broadcast` — **canonical exported function**

Enable or disable broadcast transmission.

```titan
function udp_set_broadcast(handle: udp_t, on: integer): integer
```

**Inputs and outputs:** handle: INPUT/OUTPUT initialized udp_t owner/view; mutations preserve its single owner and reserved native data slot; close completion ends native handle lifetime.; on: INPUT integer value; checked native narrowing occurs before native ownership is accepted.

**Result, lifetime and cleanup:** Return type: integer. Requires initialized UDP handle; address/buffer metadata borrowed or copied at call; async bytes retained through callback. Flags combine; connected address NULL semantics intentional.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L790).


## udp_set_membership

`uv_udp_set_membership` — **canonical exported function**

Join or leave a multicast group using the typed membership value and an optional interface address.

```titan
function udp_set_membership(handle: udp_t, multicast_addr: string, interface_addr: string?, member: membership): integer
```

**Inputs and outputs:** handle: INPUT/OUTPUT initialized udp_t owner/view; mutations preserve its single owner and reserved native data slot; close completion ends native handle lifetime.; multicast_addr: INPUT immutable text/byte owner; native C-string conventions apply where the operation takes text. The binding retains or copies bytes for accepted asynchronous uses; synchronous borrows end on return.; interface_addr: INPUT immutable text/byte owner; native C-string conventions apply where the operation takes text. The binding retains or copies bytes for accepted asynchronous uses; synchronous borrows end on return. Optional nil is meaningful; see contract.; member: INPUT membership value.

**Result, lifetime and cleanup:** Return type: integer. Requires initialized UDP handle; address/buffer metadata borrowed or copied at call; async bytes retained through callback. Flags combine; connected address NULL semantics intentional.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L777).


## udp_set_multicast_interface

`uv_udp_set_multicast_interface` — **canonical exported function**

Select the interface used for outbound multicast; nil selects native default behavior.

```titan
function udp_set_multicast_interface(handle: udp_t, interface_addr: string?): integer
```

**Inputs and outputs:** handle: INPUT/OUTPUT initialized udp_t owner/view; mutations preserve its single owner and reserved native data slot; close completion ends native handle lifetime.; interface_addr: INPUT immutable text/byte owner; native C-string conventions apply where the operation takes text. The binding retains or copies bytes for accepted asynchronous uses; synchronous borrows end on return. Optional nil is meaningful; see contract.

**Result, lifetime and cleanup:** Return type: integer. Requires initialized UDP handle; address/buffer metadata borrowed or copied at call; async bytes retained through callback. Flags combine; connected address NULL semantics intentional.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L788).


## udp_set_multicast_loop

`uv_udp_set_multicast_loop` — **canonical exported function**

Enable or disable loopback of outbound multicast datagrams to local receivers.

```titan
function udp_set_multicast_loop(handle: udp_t, on: integer): integer
```

**Inputs and outputs:** handle: INPUT/OUTPUT initialized udp_t owner/view; mutations preserve its single owner and reserved native data slot; close completion ends native handle lifetime.; on: INPUT integer value; checked native narrowing occurs before native ownership is accepted.

**Result, lifetime and cleanup:** Return type: integer. Requires initialized UDP handle; address/buffer metadata borrowed or copied at call; async bytes retained through callback. Flags combine; connected address NULL semantics intentional.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L786).


## udp_set_multicast_ttl

`uv_udp_set_multicast_ttl` — **canonical exported function**

Set the multicast hop limit/TTL using the native accepted range.

```titan
function udp_set_multicast_ttl(handle: udp_t, ttl: integer): integer
```

**Inputs and outputs:** handle: INPUT/OUTPUT initialized udp_t owner/view; mutations preserve its single owner and reserved native data slot; close completion ends native handle lifetime.; ttl: INPUT integer value; checked native narrowing occurs before native ownership is accepted.

**Result, lifetime and cleanup:** Return type: integer. Requires initialized UDP handle; address/buffer metadata borrowed or copied at call; async bytes retained through callback. Flags combine; connected address NULL semantics intentional.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L787).


## udp_set_source_membership

`uv_udp_set_source_membership` — **canonical exported function**

Join or leave a source-specific multicast group; group, interface and source strings identify the membership.

```titan
function udp_set_source_membership(handle: udp_t, multicast_addr: string, interface_addr: string?, source_addr: string, member: membership): integer
```

**Inputs and outputs:** handle: INPUT/OUTPUT initialized udp_t owner/view; mutations preserve its single owner and reserved native data slot; close completion ends native handle lifetime.; multicast_addr: INPUT immutable text/byte owner; native C-string conventions apply where the operation takes text. The binding retains or copies bytes for accepted asynchronous uses; synchronous borrows end on return.; interface_addr: INPUT immutable text/byte owner; native C-string conventions apply where the operation takes text. The binding retains or copies bytes for accepted asynchronous uses; synchronous borrows end on return. Optional nil is meaningful; see contract.; source_addr: INPUT immutable text/byte owner; native C-string conventions apply where the operation takes text. The binding retains or copies bytes for accepted asynchronous uses; synchronous borrows end on return.; member: INPUT membership value.

**Result, lifetime and cleanup:** Return type: integer. Requires initialized UDP handle; address/buffer metadata borrowed or copied at call; async bytes retained through callback. Flags combine; connected address NULL semantics intentional.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L781).


## udp_set_ttl

`uv_udp_set_ttl` — **canonical exported function**

Set the unicast datagram hop limit/TTL using the native accepted range.

```titan
function udp_set_ttl(handle: udp_t, ttl: integer): integer
```

**Inputs and outputs:** handle: INPUT/OUTPUT initialized udp_t owner/view; mutations preserve its single owner and reserved native data slot; close completion ends native handle lifetime.; ttl: INPUT integer value; checked native narrowing occurs before native ownership is accepted.

**Result, lifetime and cleanup:** Return type: integer. Requires initialized UDP handle; address/buffer metadata borrowed or copied at call; async bytes retained through callback. Flags combine; connected address NULL semantics intentional.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L791).


## udp_try_send

`uv_udp_try_send` — **canonical exported function**

Send one datagram immediately without queuing a request. Return its byte count or a negative status; use one zero-length buffer for an empty datagram.

```titan
function udp_try_send(handle: udp_t, buffers: {buf_t}, address: sockaddr_t?): integer
```

**Inputs and outputs:** handle: INPUT/OUTPUT initialized udp_t owner/view; mutations preserve its single owner and reserved native data slot; close completion ends native handle lifetime.; buffers: INPUT byte owner or vector; immutable strings are valid only for input; async submission snapshots descriptors and retains owners, so Array edits cannot alter accepted I/O; do not mutate borrowed byte contents before completion.; address: INPUT complete typed address owner; no sockaddr pointer/header required; constructor/accessors encode family/port/bytes. Native submission consumes or copies address during the call. Optional nil is meaningful; see contract.

**Result, lifetime and cleanup:** Return type: integer. Requires initialized UDP handle; address/buffer metadata borrowed or copied at call; async bytes retained through callback. Flags combine; connected address NULL semantics intentional.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L798).


## udp_try_send2

`uv_udp_try_send2` — **canonical exported function**

Immediately send a nonempty batch of datagrams using parallel buffer/address Arrays. Return the native number of messages sent or a negative status; native behavior governs partial batches.

```titan
function udp_try_send2(handle: udp_t, buffers: {{buf_t}}, addresses: {sockaddr_t?}, flags: integer): integer
```

**Inputs and outputs:** handle: INPUT/OUTPUT initialized udp_t owner/view; mutations preserve its single owner and reserved native data slot; close completion ends native handle lifetime.; buffers: INPUT byte owner or vector; immutable strings are valid only for input; async submission snapshots descriptors and retains owners, so Array edits cannot alter accepted I/O; do not mutate borrowed byte contents before completion.; addresses: INPUT complete typed address owner; no sockaddr pointer/header required; constructor/accessors encode family/port/bytes. Native submission consumes or copies address during the call.; flags: INPUT integer value; checked native narrowing occurs before native ownership is accepted.

**Result, lifetime and cleanup:** Return type: integer. Requires initialized UDP handle; address/buffer metadata borrowed or copied at call; async bytes retained through callback. Flags combine; connected address NULL semantics intentional. Returns datagram count, not bytes; preserves packet boundaries; count/vectors/counts/addresses arrays must correspond; flags 0 for pinned API.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L802).


## udp_using_recvmmsg

`uv_udp_using_recvmmsg` — **canonical exported function**

Report whether this handle actually uses native recvmmsg reception, independent of requested flags.

```titan
function udp_using_recvmmsg(handle: udp_t): boolean
```

**Inputs and outputs:** handle: INPUT/OUTPUT initialized udp_t owner/view; mutations preserve its single owner and reserved native data slot; close completion ends native handle lifetime.

**Result, lifetime and cleanup:** Return type: boolean. Requires initialized UDP handle; address/buffer metadata borrowed or copied at call; async bytes retained through callback. Flags combine; connected address NULL semantics intentional.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L811).

