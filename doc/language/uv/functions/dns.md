# dns API reference

Complete public example: [dns_tcp](../examples/dns_tcp.titan). See the
[example guide](../examples/README.md) for build/run commands and platform conditions.

getaddrinfo/getnameinfo allow synchronous nil-callback and deferred callback forms. Accepted requests retire their old registration before callback, so same-owner reuse is legal. addrinfo_result_t owns a separate native list with explicit freeaddrinfo; entries() copies records/addresses/strings into ordinary Titan values. nameinfo copies host/service strings. Native cancellation still delivers one completion after success.

## freeaddrinfo

`uv_freeaddrinfo` — **canonical exported function**

Free the native address-list result; nil is allowed. Already copied entries, names and address bytes remain ordinary Titan values.

```titan
function freeaddrinfo(result: addrinfo_result_t?)
```

**Inputs and outputs:** result: INPUT/OUTPUT separately owned native DNS result; freeaddrinfo releases native list explicitly; copied entries remain ordinary values. Optional nil is meaningful; see contract.

**Result, lifetime and cleanup:** Return type: (). Synchronous explicit release of the separately owned native DNS list; nil and an already released owner are harmless. Later entries() calls on that owner reject. Arrays, entry records, names and sockaddr values copied by earlier entries() calls remain valid.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1024).


## getaddrinfo

`uv_getaddrinfo` — **canonical exported function**

Resolve optional node/service with optional hints. A callback selects asynchronous submission; nil selects synchronous lookup. A successful addrinfo_result_t must be freed explicitly after copying/using its entries.

```titan
function getaddrinfo(loop: loop_t, request: getaddrinfo_t, callback: (function (getaddrinfo_t, integer, addrinfo_result_t?): ())?, node: string?, service: string?, hints: addrinfo_hints_t?): integer
```

**Inputs and outputs:** loop: INPUT initialized owning loop; accepted handles/requests retain it through retirement.; request: INPUT/OUTPUT allocated nonpending request owner; accepted submission retains owner until its terminal callback returns; rejection owes no async callback.; callback: INPUT ordinary callable, retained until the promised callback interval ends; the request view remains rooted through callback return; a successful addrinfo_result_t is a separate native list with explicit freeaddrinfo lifetime. Optional nil is meaningful; see contract.; node: INPUT immutable text/byte owner; native C-string conventions apply where the operation takes text. The binding retains or copies bytes for accepted asynchronous uses; synchronous borrows end on return. Optional nil is meaningful; see contract.; service: INPUT immutable text/byte owner; native C-string conventions apply where the operation takes text. The binding retains or copies bytes for accepted asynchronous uses; synchronous borrows end on return. Optional nil is meaningful; see contract.; hints: INPUT addrinfo_hints_t? value.

**Result, lifetime and cleanup:** Return type: integer. With callback nil, lookup completes synchronously and request:addrinfo() supplies status and the separate result owner. Otherwise a nonnegative submission accepts one terminal callback; a negative immediate return owes none. Native code copies node/service/hints needed after submission. Success produces an addrinfo_result_t owning a native list until explicit freeaddrinfo. entries() returns copied values that survive release; request reuse and completion do not release the list.

**Callbacks:** optional-sync-or-deferred-once. the owning main Lua thread; timing is specified above

**Cancellation:** yes: accepted async request only; callback still required

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1018).


## getnameinfo

`uv_getnameinfo` — **canonical exported function**

Resolve the typed address to host/service strings under the supplied NI_* flags. Callback results are copied strings; nil callback selects synchronous operation and request accessors supply results.

```titan
function getnameinfo(loop: loop_t, request: getnameinfo_t, callback: (function (getnameinfo_t, integer, string?, string?): ())?, address: sockaddr_t, flags: integer): integer
```

**Inputs and outputs:** loop: INPUT initialized owning loop; accepted handles/requests retain it through retirement.; request: INPUT/OUTPUT allocated nonpending request owner; accepted submission retains owner until its terminal callback returns; rejection owes no async callback.; callback: INPUT ordinary callable, retained until the promised callback interval ends; the request view remains rooted through callback return; host/service arguments are copied strings. Optional nil is meaningful; see contract.; address: INPUT complete typed address owner; no sockaddr pointer/header required; constructor/accessors encode family/port/bytes. Native submission consumes or copies address during the call.; flags: INPUT integer value; checked native narrowing occurs before native ownership is accepted.

**Result, lifetime and cleanup:** Return type: integer. With callback nil, lookup completes synchronously and request:result() supplies status and copied host/service strings. Otherwise a nonnegative submission accepts one terminal callback and negative immediate rejection owes none. The native address is copied during submission. Public callback host/service values are nullable copied strings, valid after request reuse; no public native free is involved.

**Callbacks:** optional-sync-or-deferred-once. the owning main Lua thread; timing is specified above

**Cancellation:** yes: accepted async request only; callback still required

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1040).

