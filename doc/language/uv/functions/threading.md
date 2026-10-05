# threading API reference

Complete public example: [threading_sync](../examples/threading_sync.titan). See the
[example guide](../examples/README.md) for build/run commands and platform conditions.

Native thread/once entries are C-only. Thread creation retains argument_owner through join; ordinary Titan calls are not worker-safe. Detach is allowed only with argument_owner=nil and externally valid worker code/argument memory. Detached identifier storage may be reused after native success because the worker never borrows that storage. thread_self is a borrowed identity. Synchronization owners have explicit initialization and terminal destruction; no automatic native destructor or GC release is supplied.

## barrier_destroy

`uv_barrier_destroy` — **canonical exported function**

Destroy the initialized barrier after every native user is quiescent. Collection and cancellation do not supply this synchronization.

```titan
function barrier_destroy(owner: barrier_t)
```

**Inputs and outputs:** owner: INPUT/OUTPUT initialized native synchronization owner; caller coordinates external native users and lifetime; destroy/delete only after quiescence.

**Result, lifetime and cleanup:** Return type: (). Native synchronization/thread operations are blocking OS primitives, not cooperative waits. C-only foreign workers must never access Titan/Lua; packed owners/arguments retained until native lifetime ends. Explicit destroy/join; no GC-finalizer ownership policy.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1891).


## barrier_init

`uv_barrier_init` — **canonical exported function**

Initialize a barrier for count participating native threads; count must be positive.

```titan
function barrier_init(owner: barrier_t, count: integer): integer
```

**Inputs and outputs:** owner: INPUT/OUTPUT fresh final barrier_t() storage; explicit destroy/delete after native users retire.; count: INPUT integer value; checked native narrowing occurs before native ownership is accepted.

**Result, lifetime and cleanup:** Return type: integer. Requires fresh final synchronization storage; an initialized or terminally destroyed/deleted owner raises. Native success establishes the lifetime; a negative native result leaves the owner fresh for another attempt. Use the matching destroy operation after all native users are quiescent. Explicit destruction/deletion is terminal for this owner; allocate another owner for a new lifetime.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1890).


## barrier_wait

`uv_barrier_wait` — **canonical exported function**

Block at the native barrier until all participants arrive. Returns a positive value for one participant and zero for the others.

```titan
function barrier_wait(owner: barrier_t): integer
```

**Inputs and outputs:** owner: INPUT/OUTPUT initialized native synchronization owner; caller coordinates external native users and lifetime; destroy/delete only after quiescence.

**Result, lifetime and cleanup:** Return type: integer. Requires a live initialized barrier; blocks the native thread until all participants arrive. Returns a positive value for one participant and 0 for the others, not a conventional error/status channel. Coordinate native users before barrier_destroy. Calling this Titan wrapper blocks the Lua thread; native workers use the C-only entry.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1892).


## cond_broadcast

`uv_cond_broadcast` — **canonical exported function**

Wake all native condition waiters, if any.

```titan
function cond_broadcast(owner: cond_t)
```

**Inputs and outputs:** owner: INPUT/OUTPUT initialized native synchronization owner; caller coordinates external native users and lifetime; destroy/delete only after quiescence.

**Result, lifetime and cleanup:** Return type: (). Native synchronization/thread operations are blocking OS primitives, not cooperative waits. C-only foreign workers must never access Titan/Lua; packed owners/arguments retained until native lifetime ends. Explicit destroy/join; no GC-finalizer ownership policy.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1888).


## cond_destroy

`uv_cond_destroy` — **canonical exported function**

Destroy the initialized cond after every native user is quiescent. Collection and cancellation do not supply this synchronization.

```titan
function cond_destroy(owner: cond_t)
```

**Inputs and outputs:** owner: INPUT/OUTPUT initialized native synchronization owner; caller coordinates external native users and lifetime; destroy/delete only after quiescence.

**Result, lifetime and cleanup:** Return type: (). Native synchronization/thread operations are blocking OS primitives, not cooperative waits. C-only foreign workers must never access Titan/Lua; packed owners/arguments retained until native lifetime ends. Explicit destroy/join; no GC-finalizer ownership policy.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1886).


## cond_init

`uv_cond_init` — **canonical exported function**

Initialize a condition variable; its waits require a separately initialized mutex.

```titan
function cond_init(owner: cond_t): integer
```

**Inputs and outputs:** owner: INPUT/OUTPUT fresh final cond_t() storage; explicit destroy/delete after native users retire.

**Result, lifetime and cleanup:** Return type: integer. Requires fresh final synchronization storage; an initialized or terminally destroyed/deleted owner raises. Native success establishes the lifetime; a negative native result leaves the owner fresh for another attempt. Use the matching destroy operation after all native users are quiescent. Explicit destruction/deletion is terminal for this owner; allocate another owner for a new lifetime.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1885).


## cond_signal

`uv_cond_signal` — **canonical exported function**

Wake one native waiter, if any. A condition notification is not a stored Task event.

```titan
function cond_signal(owner: cond_t)
```

**Inputs and outputs:** owner: INPUT/OUTPUT initialized native synchronization owner; caller coordinates external native users and lifetime; destroy/delete only after quiescence.

**Result, lifetime and cleanup:** Return type: (). Native synchronization/thread operations are blocking OS primitives, not cooperative waits. C-only foreign workers must never access Titan/Lua; packed owners/arguments retained until native lifetime ends. Explicit destroy/join; no GC-finalizer ownership policy.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1887).


## cond_timedwait

`uv_cond_timedwait` — **canonical exported function**

Wait with a relative unsigned nanosecond timeout while releasing/reacquiring the mutex. Returns zero when notified or the native timeout/error status.

```titan
function cond_timedwait(owner: cond_t, mutex: mutex_t, timeout_ns: foreign unsigned long long): integer
```

**Inputs and outputs:** owner: INPUT/OUTPUT initialized native synchronization owner; caller coordinates external native users and lifetime; destroy/delete only after quiescence.; mutex: INPUT/OUTPUT initialized native synchronization owner; caller coordinates external native users and lifetime; destroy/delete only after quiescence.; timeout_ns: INPUT foreign unsigned long long value; checked native narrowing occurs before native ownership is accepted.

**Result, lifetime and cleanup:** Return type: integer. Native synchronization/thread operations are blocking OS primitives, not cooperative waits. C-only foreign workers must never access Titan/Lua; packed owners/arguments retained until native lifetime ends. Explicit destroy/join; no GC-finalizer ownership policy. Relative timeout nanoseconds; mutex released/reacquired; ETIMEDOUT is status, spurious wake possible.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1895).


## cond_wait

`uv_cond_wait` — **canonical exported function**

Atomically release the supplied locked mutex and wait, then reacquire it before returning. Check the caller's condition in a loop; this blocks the OS thread.

```titan
function cond_wait(owner: cond_t, mutex: mutex_t)
```

**Inputs and outputs:** owner: INPUT/OUTPUT initialized native synchronization owner; caller coordinates external native users and lifetime; destroy/delete only after quiescence.; mutex: INPUT/OUTPUT initialized native synchronization owner; caller coordinates external native users and lifetime; destroy/delete only after quiescence.

**Result, lifetime and cleanup:** Return type: (). Native synchronization/thread operations are blocking OS primitives, not cooperative waits. C-only foreign workers must never access Titan/Lua; packed owners/arguments retained until native lifetime ends. Explicit destroy/join; no GC-finalizer ownership policy. Atomically unlocks/relocks supplied initialized mutex around native wait; may return spuriously; caller predicate loop required.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1894).


## key_create

`uv_key_create` — **canonical exported function**

Create a native thread-local-storage key. Values are raw external pointers, not traced Titan values.

```titan
function key_create(owner: key_t): integer
```

**Inputs and outputs:** owner: INPUT/OUTPUT fresh final key_t() storage; explicit destroy/delete after native users retire.

**Result, lifetime and cleanup:** Return type: integer. Requires fresh final synchronization storage; an initialized or terminally destroyed/deleted owner raises. Native success establishes the lifetime; a negative native result leaves the owner fresh for another attempt. Use key_delete after all native users are quiescent. Explicit destruction/deletion is terminal for this owner; allocate another owner for a new lifetime.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1901).


## key_delete

`uv_key_delete` — **canonical exported function**

Delete the native key after its users stop. This does not free pointed-to application data.

```titan
function key_delete(owner: key_t)
```

**Inputs and outputs:** owner: INPUT/OUTPUT initialized native synchronization owner; caller coordinates external native users and lifetime; destroy/delete only after quiescence.

**Result, lifetime and cleanup:** Return type: (). Native synchronization/thread operations are blocking OS primitives, not cooperative waits. C-only foreign workers must never access Titan/Lua; packed owners/arguments retained until native lifetime ends. Explicit destroy/join; no GC-finalizer ownership policy. Destroys TLS key only; does not free all per-thread stored values.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1902).


## key_get

`uv_key_get` — **canonical exported function**

Return the raw value associated with this key on the calling native thread; nil is the null pointer.

```titan
function key_get(owner: key_t): foreign *void
```

**Inputs and outputs:** owner: INPUT/OUTPUT initialized native synchronization owner; caller coordinates external native users and lifetime; destroy/delete only after quiescence.

**Result, lifetime and cleanup:** Return type: foreign *void. Native synchronization/thread operations are blocking OS primitives, not cooperative waits. C-only foreign workers must never access Titan/Lua; packed owners/arguments retained until native lifetime ends. Explicit destroy/join; no GC-finalizer ownership policy. Returns per-native-thread opaque pointer; no ownership transfer; storage not automatically traced.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1903).


## key_set

`uv_key_set` — **canonical exported function**

Store a raw pointer for this key on the calling native thread. Retaining the pointed-to memory is the caller's responsibility.

```titan
function key_set(owner: key_t, value: foreign *void)
```

**Inputs and outputs:** owner: INPUT/OUTPUT initialized native synchronization owner; caller coordinates external native users and lifetime; destroy/delete only after quiescence.; value: INPUT borrowed native address for explicit C-only/TLS interop; no automatic GC ownership. Retain its complete backing graph using the associated owner parameter or external lifetime.

**Result, lifetime and cleanup:** Return type: (). Native synchronization/thread operations are blocking OS primitives, not cooperative waits. C-only foreign workers must never access Titan/Lua; packed owners/arguments retained until native lifetime ends. Explicit destroy/join; no GC-finalizer ownership policy.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1904).


## mutex_destroy

`uv_mutex_destroy` — **canonical exported function**

Destroy the initialized mutex after every native user is quiescent. Collection and cancellation do not supply this synchronization.

```titan
function mutex_destroy(owner: mutex_t)
```

**Inputs and outputs:** owner: INPUT/OUTPUT initialized native synchronization owner; caller coordinates external native users and lifetime; destroy/delete only after quiescence.

**Result, lifetime and cleanup:** Return type: (). Native synchronization/thread operations are blocking OS primitives, not cooperative waits. C-only foreign workers must never access Titan/Lua; packed owners/arguments retained until native lifetime ends. Explicit destroy/join; no GC-finalizer ownership policy.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1865).


## mutex_init

`uv_mutex_init` — **canonical exported function**

Initialize a nonrecursive mutex.

```titan
function mutex_init(owner: mutex_t): integer
```

**Inputs and outputs:** owner: INPUT/OUTPUT fresh final mutex_t() storage; explicit destroy/delete after native users retire.

**Result, lifetime and cleanup:** Return type: integer. Requires fresh final synchronization storage; an initialized or terminally destroyed/deleted owner raises. Native success establishes the lifetime; a negative native result leaves the owner fresh for another attempt. Use the matching destroy operation after all native users are quiescent. Explicit destruction/deletion is terminal for this owner; allocate another owner for a new lifetime.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1863).


## mutex_init_recursive

`uv_mutex_init_recursive` — **canonical exported function**

Initialize a mutex permitting repeated lock by its current native-thread owner.

```titan
function mutex_init_recursive(owner: mutex_t): integer
```

**Inputs and outputs:** owner: INPUT/OUTPUT fresh final mutex_t() storage; explicit destroy/delete after native users retire.

**Result, lifetime and cleanup:** Return type: integer. Requires fresh final synchronization storage; an initialized or terminally destroyed/deleted owner raises. Native success establishes the lifetime; a negative native result leaves the owner fresh for another attempt. Use the matching destroy operation after all native users are quiescent. Explicit destruction/deletion is terminal for this owner; allocate another owner for a new lifetime.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1864).


## mutex_lock

`uv_mutex_lock` — **canonical exported function**

Block the OS thread until the mutex can be acquired.

```titan
function mutex_lock(owner: mutex_t)
```

**Inputs and outputs:** owner: INPUT/OUTPUT initialized native synchronization owner; caller coordinates external native users and lifetime; destroy/delete only after quiescence.

**Result, lifetime and cleanup:** Return type: (). Native synchronization/thread operations are blocking OS primitives, not cooperative waits. C-only foreign workers must never access Titan/Lua; packed owners/arguments retained until native lifetime ends. Explicit destroy/join; no GC-finalizer ownership policy.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1866).


## mutex_trylock

`uv_mutex_trylock` — **canonical exported function**

Attempt immediate mutex acquisition; zero acquires it and a native busy/error result leaves it unacquired.

```titan
function mutex_trylock(owner: mutex_t): integer
```

**Inputs and outputs:** owner: INPUT/OUTPUT initialized native synchronization owner; caller coordinates external native users and lifetime; destroy/delete only after quiescence.

**Result, lifetime and cleanup:** Return type: integer. Native synchronization/thread operations are blocking OS primitives, not cooperative waits. C-only foreign workers must never access Titan/Lua; packed owners/arguments retained until native lifetime ends. Explicit destroy/join; no GC-finalizer ownership policy.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1867).


## mutex_unlock

`uv_mutex_unlock` — **canonical exported function**

Release one matching mutex acquisition by the owning native thread.

```titan
function mutex_unlock(owner: mutex_t)
```

**Inputs and outputs:** owner: INPUT/OUTPUT initialized native synchronization owner; caller coordinates external native users and lifetime; destroy/delete only after quiescence.

**Result, lifetime and cleanup:** Return type: (). Native synchronization/thread operations are blocking OS primitives, not cooperative waits. C-only foreign workers must never access Titan/Lua; packed owners/arguments retained until native lifetime ends. Explicit destroy/join; no GC-finalizer ownership policy.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1868).


## once

`uv_once` — **canonical exported function**

Invoke one C-only callback exactly once for the once_t guard, with native cross-thread synchronization. The callback cannot enter Lua/Titan.

```titan
function once(guard: once_t, callback: foreign function(): void)
```

**Inputs and outputs:** guard: INPUT/OUTPUT initialized native synchronization owner; caller coordinates external native users and lifetime; destroy/delete only after quiescence.; callback: INPUT C-only entry; no Lua/Titan execution from a native worker/once callback. Keep code loaded for every invocation.

**Result, lifetime and cleanup:** Return type: (). Native synchronization/thread operations are blocking OS primitives, not cooperative waits. C-only foreign workers must never access Titan/Lua; packed owners/arguments retained until native lifetime ends. Explicit destroy/join; no GC-finalizer ownership policy. Initialize guard with UV_ONCE_INIT. Callback may be executed by whichever native caller wins, including foreign thread; never enter Lua/Titan. Native primitive may block waiting on another caller.

**Callbacks:** synchronous-c-only-at-most-once. C-only potentially foreign thread

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1899).


## rwlock_destroy

`uv_rwlock_destroy` — **canonical exported function**

Destroy the initialized rwlock after every native user is quiescent. Collection and cancellation do not supply this synchronization.

```titan
function rwlock_destroy(owner: rwlock_t)
```

**Inputs and outputs:** owner: INPUT/OUTPUT initialized native synchronization owner; caller coordinates external native users and lifetime; destroy/delete only after quiescence.

**Result, lifetime and cleanup:** Return type: (). Native synchronization/thread operations are blocking OS primitives, not cooperative waits. C-only foreign workers must never access Titan/Lua; packed owners/arguments retained until native lifetime ends. Explicit destroy/join; no GC-finalizer ownership policy.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1871).


## rwlock_init

`uv_rwlock_init` — **canonical exported function**

Initialize a native reader/writer lock.

```titan
function rwlock_init(owner: rwlock_t): integer
```

**Inputs and outputs:** owner: INPUT/OUTPUT fresh final rwlock_t() storage; explicit destroy/delete after native users retire.

**Result, lifetime and cleanup:** Return type: integer. Requires fresh final synchronization storage; an initialized or terminally destroyed/deleted owner raises. Native success establishes the lifetime; a negative native result leaves the owner fresh for another attempt. Use the matching destroy operation after all native users are quiescent. Explicit destruction/deletion is terminal for this owner; allocate another owner for a new lifetime.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1870).


## rwlock_rdlock

`uv_rwlock_rdlock` — **canonical exported function**

Block until a read-side lock is acquired.

```titan
function rwlock_rdlock(owner: rwlock_t)
```

**Inputs and outputs:** owner: INPUT/OUTPUT initialized native synchronization owner; caller coordinates external native users and lifetime; destroy/delete only after quiescence.

**Result, lifetime and cleanup:** Return type: (). Native synchronization/thread operations are blocking OS primitives, not cooperative waits. C-only foreign workers must never access Titan/Lua; packed owners/arguments retained until native lifetime ends. Explicit destroy/join; no GC-finalizer ownership policy.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1872).


## rwlock_rdunlock

`uv_rwlock_rdunlock` — **canonical exported function**

Release a matching read-side acquisition.

```titan
function rwlock_rdunlock(owner: rwlock_t)
```

**Inputs and outputs:** owner: INPUT/OUTPUT initialized native synchronization owner; caller coordinates external native users and lifetime; destroy/delete only after quiescence.

**Result, lifetime and cleanup:** Return type: (). Native synchronization/thread operations are blocking OS primitives, not cooperative waits. C-only foreign workers must never access Titan/Lua; packed owners/arguments retained until native lifetime ends. Explicit destroy/join; no GC-finalizer ownership policy.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1874).


## rwlock_tryrdlock

`uv_rwlock_tryrdlock` — **canonical exported function**

Attempt immediate read-side acquisition and return native success/busy status.

```titan
function rwlock_tryrdlock(owner: rwlock_t): integer
```

**Inputs and outputs:** owner: INPUT/OUTPUT initialized native synchronization owner; caller coordinates external native users and lifetime; destroy/delete only after quiescence.

**Result, lifetime and cleanup:** Return type: integer. Native synchronization/thread operations are blocking OS primitives, not cooperative waits. C-only foreign workers must never access Titan/Lua; packed owners/arguments retained until native lifetime ends. Explicit destroy/join; no GC-finalizer ownership policy.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1873).


## rwlock_trywrlock

`uv_rwlock_trywrlock` — **canonical exported function**

Attempt immediate exclusive write-side acquisition and return native success/busy status.

```titan
function rwlock_trywrlock(owner: rwlock_t): integer
```

**Inputs and outputs:** owner: INPUT/OUTPUT initialized native synchronization owner; caller coordinates external native users and lifetime; destroy/delete only after quiescence.

**Result, lifetime and cleanup:** Return type: integer. Native synchronization/thread operations are blocking OS primitives, not cooperative waits. C-only foreign workers must never access Titan/Lua; packed owners/arguments retained until native lifetime ends. Explicit destroy/join; no GC-finalizer ownership policy.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1876).


## rwlock_wrlock

`uv_rwlock_wrlock` — **canonical exported function**

Block until the exclusive write-side lock is acquired.

```titan
function rwlock_wrlock(owner: rwlock_t)
```

**Inputs and outputs:** owner: INPUT/OUTPUT initialized native synchronization owner; caller coordinates external native users and lifetime; destroy/delete only after quiescence.

**Result, lifetime and cleanup:** Return type: (). Native synchronization/thread operations are blocking OS primitives, not cooperative waits. C-only foreign workers must never access Titan/Lua; packed owners/arguments retained until native lifetime ends. Explicit destroy/join; no GC-finalizer ownership policy.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1875).


## rwlock_wrunlock

`uv_rwlock_wrunlock` — **canonical exported function**

Release a matching write-side acquisition.

```titan
function rwlock_wrunlock(owner: rwlock_t)
```

**Inputs and outputs:** owner: INPUT/OUTPUT initialized native synchronization owner; caller coordinates external native users and lifetime; destroy/delete only after quiescence.

**Result, lifetime and cleanup:** Return type: (). Native synchronization/thread operations are blocking OS primitives, not cooperative waits. C-only foreign workers must never access Titan/Lua; packed owners/arguments retained until native lifetime ends. Explicit destroy/join; no GC-finalizer ownership policy.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1877).


## sem_destroy

`uv_sem_destroy` — **canonical exported function**

Destroy the initialized sem after every native user is quiescent. Collection and cancellation do not supply this synchronization.

```titan
function sem_destroy(owner: sem_t)
```

**Inputs and outputs:** owner: INPUT/OUTPUT initialized native synchronization owner; caller coordinates external native users and lifetime; destroy/delete only after quiescence.

**Result, lifetime and cleanup:** Return type: (). Native synchronization/thread operations are blocking OS primitives, not cooperative waits. C-only foreign workers must never access Titan/Lua; packed owners/arguments retained until native lifetime ends. Explicit destroy/join; no GC-finalizer ownership policy.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1880).


## sem_init

`uv_sem_init` — **canonical exported function**

Initialize a semaphore with the supplied nonnegative count.

```titan
function sem_init(owner: sem_t, value: integer): integer
```

**Inputs and outputs:** owner: INPUT/OUTPUT fresh final sem_t() storage; explicit destroy/delete after native users retire.; value: INPUT integer value; checked native narrowing occurs before native ownership is accepted.

**Result, lifetime and cleanup:** Return type: integer. Requires fresh final synchronization storage; an initialized or terminally destroyed/deleted owner raises. Native success establishes the lifetime; a negative native result leaves the owner fresh for another attempt. Use the matching destroy operation after all native users are quiescent. Explicit destruction/deletion is terminal for this owner; allocate another owner for a new lifetime.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1879).


## sem_post

`uv_sem_post` — **canonical exported function**

Increment the semaphore and release one waiting native thread when applicable.

```titan
function sem_post(owner: sem_t)
```

**Inputs and outputs:** owner: INPUT/OUTPUT initialized native synchronization owner; caller coordinates external native users and lifetime; destroy/delete only after quiescence.

**Result, lifetime and cleanup:** Return type: (). Native synchronization/thread operations are blocking OS primitives, not cooperative waits. C-only foreign workers must never access Titan/Lua; packed owners/arguments retained until native lifetime ends. Explicit destroy/join; no GC-finalizer ownership policy.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1881).


## sem_trywait

`uv_sem_trywait` — **canonical exported function**

Attempt immediate semaphore decrement; return native success or unavailable status.

```titan
function sem_trywait(owner: sem_t): integer
```

**Inputs and outputs:** owner: INPUT/OUTPUT initialized native synchronization owner; caller coordinates external native users and lifetime; destroy/delete only after quiescence.

**Result, lifetime and cleanup:** Return type: integer. Native synchronization/thread operations are blocking OS primitives, not cooperative waits. C-only foreign workers must never access Titan/Lua; packed owners/arguments retained until native lifetime ends. Explicit destroy/join; no GC-finalizer ownership policy.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1883).


## sem_wait

`uv_sem_wait` — **canonical exported function**

Block the OS thread until the semaphore can be decremented.

```titan
function sem_wait(owner: sem_t)
```

**Inputs and outputs:** owner: INPUT/OUTPUT initialized native synchronization owner; caller coordinates external native users and lifetime; destroy/delete only after quiescence.

**Result, lifetime and cleanup:** Return type: (). Native synchronization/thread operations are blocking OS primitives, not cooperative waits. C-only foreign workers must never access Titan/Lua; packed owners/arguments retained until native lifetime ends. Explicit destroy/join; no GC-finalizer ownership policy.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1882).


## thread_create

`uv_thread_create` — **canonical exported function**

Start a native thread at the C-only entry(argument), retaining argument_owner until a successful join. A nil owner explicitly borrows externally managed storage.

```titan
function thread_create(thread: thread_t, entry: foreign function(*void): void, argument: foreign *void, argument_owner: value): integer
```

**Inputs and outputs:** thread: INPUT/OUTPUT thread identifier owner; create requires fresh/retired owner, join retains argument graph until completion, detach requires argument_owner=nil; thread_self returns a borrowed identity.; entry: INPUT C-only entry; no Lua/Titan execution from a native worker/once callback. Keep code loaded for every invocation.; argument: INPUT borrowed native address for explicit C-only/TLS interop; no automatic GC ownership. Retain its complete backing graph using the associated owner parameter or external lifetime.; argument_owner: INPUT traced argument-owner graph retained through native worker completion/join.

**Result, lifetime and cleanup:** Return type: integer. Native synchronization/thread operations are blocking OS primitives, not cooperative waits. C-only foreign workers must never access Titan/Lua; packed owners/arguments retained until native lifetime ends. Explicit destroy/join; no GC-finalizer ownership policy. Entry is C-only; explicit native argument ownership through exit; resulting native thread token needs join or detach lifecycle. Starting thread can begin before create returns.

**Callbacks:** foreign-thread-once. C-only potentially foreign thread

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1910).


## thread_create_ex

`uv_thread_create_ex` — **canonical exported function**

Start a native thread with thread_options_t flags/stack size and the same C-only entry and ownership contract as thread_create.

```titan
function thread_create_ex(thread: thread_t, options: thread_options_t, entry: foreign function(*void): void, argument: foreign *void, argument_owner: value): integer
```

**Inputs and outputs:** thread: INPUT/OUTPUT thread identifier owner; create requires fresh/retired owner, join retains argument graph until completion, detach requires argument_owner=nil; thread_self returns a borrowed identity.; options: INPUT thread_options_t value.; entry: INPUT C-only entry; no Lua/Titan execution from a native worker/once callback. Keep code loaded for every invocation.; argument: INPUT borrowed native address for explicit C-only/TLS interop; no automatic GC ownership. Retain its complete backing graph using the associated owner parameter or external lifetime.; argument_owner: INPUT traced argument-owner graph retained through native worker completion/join.

**Result, lifetime and cleanup:** Return type: integer. Native synchronization/thread operations are blocking OS primitives, not cooperative waits. C-only foreign workers must never access Titan/Lua; packed owners/arguments retained until native lifetime ends. Explicit destroy/join; no GC-finalizer ownership policy. Like create; options input has flags and stack-size bytes, may grow in future versions. Zero stack_size uses default; native rounds to page boundary.

**Callbacks:** foreign-thread-once. C-only potentially foreign thread

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1926).


## thread_detach

`uv_thread_detach` — **canonical exported function**

Relinquish the join obligation only for a thread created with nil argument_owner. Code and argument storage must remain externally valid for its remaining native lifetime.

```titan
function thread_detach(thread: thread_t): integer
```

**Inputs and outputs:** thread: INPUT/OUTPUT thread identifier owner; create requires fresh/retired owner, join retains argument graph until completion, detach requires argument_owner=nil; thread_self returns a borrowed identity.

**Result, lifetime and cleanup:** Return type: integer. Native synchronization/thread operations are blocking OS primitives, not cooperative waits. C-only foreign workers must never access Titan/Lua; packed owners/arguments retained until native lifetime ends. Explicit destroy/join; no GC-finalizer ownership policy. Detaches thread token; releases native thread resource on termination, but provides no callback proving borrowed native argument can be freed. Detached C argument lifetime needs explicit policy.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1911).


## thread_equal

`uv_thread_equal` — **canonical exported function**

Compare native thread identities; the result is boolean.

```titan
function thread_equal(left: thread_t, right: thread_t): boolean
```

**Inputs and outputs:** left: INPUT/OUTPUT thread identifier owner; create requires fresh/retired owner, join retains argument graph until completion, detach requires argument_owner=nil; thread_self returns a borrowed identity.; right: INPUT/OUTPUT thread identifier owner; create requires fresh/retired owner, join retains argument graph until completion, detach requires argument_owner=nil; thread_self returns a borrowed identity.

**Result, lifetime and cleanup:** Return type: boolean. Native synchronization/thread operations are blocking OS primitives, not cooperative waits. C-only foreign workers must never access Titan/Lua; packed owners/arguments retained until native lifetime ends. Explicit destroy/join; no GC-finalizer ownership policy.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1940).


## thread_getaffinity

`uv_thread_getaffinity` — **canonical exported function**

Write the thread's affinity mask into owned char[] storage sized using cpumask_size.

```titan
function thread_getaffinity(thread: thread_t, mask: owned char[]): integer
```

**Inputs and outputs:** thread: INPUT/OUTPUT thread identifier owner; create requires fresh/retired owner, join retains argument graph until completion, detach requires argument_owner=nil; thread_self returns a borrowed identity.; mask: OUTPUT owned byte array; capacity is its Array length, retained by caller through native operation.

**Result, lifetime and cleanup:** Return type: integer. Requires a live thread identifier. mask is writable OUTPUT storage; its Array length supplies native capacity and must meet the platform cpumask_size requirement. Returns native status. No native storage escapes; unsupported platforms preserve their error status.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1934).


## thread_getcpu

`uv_thread_getcpu` — **canonical exported function**

Return the native current CPU identifier, or the native failure result where unsupported.

```titan
function thread_getcpu(): integer
```

**Result, lifetime and cleanup:** Return type: integer. Synchronously returns the native current-CPU result for the calling thread, including native errors. It needs no thread_t and creates no resource; the ordinary Titan wrapper runs on the Lua thread.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1937).


## thread_getname

`uv_thread_getname` — **canonical exported function**

Copy a thread name into a temporary buffer of capacity bytes and return `(status, name?)`.

```titan
function thread_getname(thread: thread_t, capacity: integer): (integer, string?)
```

**Inputs and outputs:** thread: INPUT/OUTPUT thread identifier owner; create requires fresh/retired owner, join retains argument graph until completion, detach requires argument_owner=nil; thread_self returns a borrowed identity.; capacity: INPUT integer value; checked native narrowing occurs before native ownership is accepted.

**Result, lifetime and cleanup:** Return type: (integer, string?). Requires a live thread identifier and positive capacity. The binding allocates temporary bytes internally; success returns 0 and a copied name string, failure returns status and nil. Retaining the string after thread retirement is valid.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1942).


## thread_getpriority

`uv_thread_getpriority` — **canonical exported function**

Return `(status, priority?)` for the specified native thread.

```titan
function thread_getpriority(thread: thread_t): (integer, integer?)
```

**Inputs and outputs:** thread: INPUT/OUTPUT thread identifier owner; create requires fresh/retired owner, join retains argument graph until completion, detach requires argument_owner=nil; thread_self returns a borrowed identity.

**Result, lifetime and cleanup:** Return type: (integer, integer?). Requires a live thread identifier. Synchronous success returns 0 and a copied integer priority; failure returns status and nil. No native ownership is created.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1367).


## thread_join

`uv_thread_join` — **canonical exported function**

Block until the thread exits, then retire the join obligation and retained argument owner. Call only where blocking the caller is acceptable.

```titan
function thread_join(thread: thread_t): integer
```

**Inputs and outputs:** thread: INPUT/OUTPUT thread identifier owner; create requires fresh/retired owner, join retains argument graph until completion, detach requires argument_owner=nil; thread_self returns a borrowed identity.

**Result, lifetime and cleanup:** Return type: integer. Native synchronization/thread operations are blocking OS primitives, not cooperative waits. C-only foreign workers must never access Titan/Lua; packed owners/arguments retained until native lifetime ends. Explicit destroy/join; no GC-finalizer ownership policy. Blocks until thread exits, then resource token may retire. Calling join from loop thread can block all callbacks; joining self invalid.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1939).


## thread_self

`uv_thread_self` — **canonical exported function**

Return a borrowed identity token for the calling native thread. This does not create a join/detach obligation.

```titan
function thread_self(): thread_t
```

**Result, lifetime and cleanup:** Return type: thread_t. Returns a borrowed native identity for the calling thread. The token keeps no worker argument graph alive and cannot be joined or detached through the created-thread ownership path. No native thread is created.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1938).


## thread_setaffinity

`uv_thread_setaffinity` — **canonical exported function**

Apply the supplied affinity mask and optionally write the prior mask into oldmask. The buffers are caller-owned and native platform restrictions apply.

```titan
function thread_setaffinity(thread: thread_t, mask: owned char[], oldmask: (owned char[])?): integer
```

**Inputs and outputs:** thread: INPUT/OUTPUT thread identifier owner; create requires fresh/retired owner, join retains argument graph until completion, detach requires argument_owner=nil; thread_self returns a borrowed identity.; mask: INPUT owned byte array; capacity is its Array length, retained by caller through native operation.; oldmask: OUTPUT owned byte array; capacity is its Array length, retained by caller through native operation. Optional nil is meaningful; see contract.

**Result, lifetime and cleanup:** Return type: integer. Requires a live thread identifier. mask is INPUT storage; optional oldmask is OUTPUT storage and must be at least as long as mask. The mask length supplies native capacity. Native status and platform update/read atomicity are preserved. No new thread ownership is created.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1930).


## thread_setname

`uv_thread_setname` — **canonical exported function**

Set the calling native thread's name. Native byte-length and platform restrictions apply.

```titan
function thread_setname(name: string): integer
```

**Inputs and outputs:** name: INPUT immutable text/byte owner; native C-string conventions apply where the operation takes text. The binding retains or copies bytes for accepted asynchronous uses; synchronous borrows end on return.

**Result, lifetime and cleanup:** Return type: integer. Synchronously names the calling thread and returns native status. Embedded NUL is rejected. It needs no thread_t; a foreign carrier uses the explicit C-only entry to name its own worker.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1941).


## thread_setpriority

`uv_thread_setpriority` — **canonical exported function**

Set the specified native thread's numeric priority; values are priority levels, not bit flags.

```titan
function thread_setpriority(thread: thread_t, priority: integer): integer
```

**Inputs and outputs:** thread: INPUT/OUTPUT thread identifier owner; create requires fresh/retired owner, join retains argument graph until completion, detach requires argument_owner=nil; thread_self returns a borrowed identity.; priority: INPUT integer value; checked native narrowing occurs before native ownership is accepted.

**Result, lifetime and cleanup:** Return type: integer. Native synchronization/thread operations are blocking OS primitives, not cooperative waits. C-only foreign workers must never access Titan/Lua; packed owners/arguments retained until native lifetime ends. Explicit destroy/join; no GC-finalizer ownership policy.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1368).

