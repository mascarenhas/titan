# request API reference

Complete public example: [work_random](../examples/work_random.titan). See the
[example guide](../examples/README.md) for build/run commands and platform conditions.

Accepted request storage and all required inputs survive until terminal native completion, independent of user GC or cancellation. Old registration retires before user callback and owner remains rooted through callback return. cancel is supported only for FS, getaddrinfo/getnameinfo, random, and work, and successful cancellation still requires terminal completion.

## Concrete request data

`fs_t`, `work_t`, `getaddrinfo_t`, `connect_t`, `write_t`, and `shutdown_t`
provide `get_data(): value` and `set_data(data: value)` methods. They access
the same traced public slot as `req_t:get_data` and `req_t:set_data`, without
constructing a request view. A value set through either form is immediately
visible through the other with the same identity. The initial value is nil;
false is an ordinary payload, and setting nil clears the slot.

These methods work before submission, while pending, after completion, and
after filesystem request cleanup. The stored value remains traced until it is
replaced, cleared, or the request owner becomes unreachable. Changing this
public data does not change the reserved native `.data` association or release
pending-request ownership. See [request types and signatures](../types.md).

## cancel

`uv_cancel` — **canonical exported function**

Attempt cancellation of a pending cancellable request. A successful result still requires its terminal callback, normally with ECANCELED; EBUSY leaves the ordinary completion obligation intact.

```titan
function cancel(request: req_t): integer
```

**Inputs and outputs:** request: INPUT accepted request view; native request kind and current state decide supported/success/busy; no root is released by cancellation.

**Result, lifetime and cleanup:** Return type: integer. Requires a currently accepted pending request for a meaningful cancellation attempt; the native request kind and progress decide the returned status. Supported kinds are FS, getaddrinfo/getnameinfo, random and work. Unsupported kinds return EINVAL and work already running/completed can return EBUSY. Success still owes terminal completion, normally ECANCELED, and never frees the request, borrowed buffers or other owners.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L1200).


## req_get_data

`uv_req_get_data` — **canonical exported function**

Return the separate traced Titan userdata value, initially nil. The binding's native `.data` slot remains reserved and is not exposed.

```titan
function req_get_data(req: req_t): value
```

**Inputs and outputs:** req: INPUT allocated request owner/view, including fresh, pending or completed state; this is a data/type/association query, not a pending-result read or a new submission.

**Result, lifetime and cleanup:** Return type: value. Accepts a view of any allocated concrete request owner, including before submission, while pending, after completion and after FS cleanup. Returns separate traced public data, initially nil. This is not a request-result read or submission.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L491).


## req_get_type

`uv_req_get_type` — **canonical exported function**

Return the tagged native handle/request kind. This does not initialize, submit, or complete an operation.

```titan
function req_get_type(req: req_t): req_type
```

**Inputs and outputs:** req: INPUT allocated request owner/view, including fresh, pending or completed state; this is a data/type/association query, not a pending-result read or a new submission.

**Result, lifetime and cleanup:** Return type: req_type. Accepts a view of an allocated concrete request owner; no submission or completed-result precondition is imposed. Returns the stored native request kind as req_type. Fresh zeroed native request storage reports unknown. Reading the type does not submit work, authorize concurrent reuse or expose a pending operation result.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L493).


## req_set_data

`uv_req_set_data` — **canonical exported function**

Replace the separate traced Titan userdata value; nil clears it. This does not change native lifetime or overwrite the binding's reserved `.data` pointer.

```titan
function req_set_data(req: req_t, data: value)
```

**Inputs and outputs:** req: INPUT allocated request owner/view, including fresh, pending or completed state; this is a data/type/association query, not a pending-result read or a new submission.; data: INPUT traced public data, stored separately from reserved native .data; nil clears the value.

**Result, lifetime and cleanup:** Return type: (). Accepts a view of any allocated concrete request owner, including before submission, while pending, after completion and after FS cleanup. Replaces separate traced public data, including nil. It does not alter the reserved native .data slot, submit work or release pending ownership.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L492).


## req_size

`uv_req_size` — **canonical exported function**

Return the native byte-size query for the selected kind. Use a concrete Titan constructor to allocate actual owner storage.

```titan
function req_size(kind: req_type): integer
```

**Inputs and outputs:** kind: INPUT req_type value; checked native narrowing occurs before native ownership is accepted.

**Result, lifetime and cleanup:** Return type: integer. Takes a req_type value, not a request owner; no initialized or submitted request is required. Returns the native byte-size result for that kind, including the native unsupported-kind size result. Construct a concrete request owner for allocation.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L490).


## req_type_name

`uv_req_type_name` — **canonical exported function**

Return the native name for a kind, or nil when no name is available. The result is a copied Titan string.

```titan
function req_type_name(kind: req_type): string?
```

**Inputs and outputs:** kind: INPUT req_type value; checked native narrowing occurs before native ownership is accepted.

**Result, lifetime and cleanup:** Return type: string?. Takes a req_type value, not a request owner; no initialized or submitted request is required. Returns a copied native name or nil when native lookup has no name.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L494).
