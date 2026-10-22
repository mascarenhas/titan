# Supplemental public API reference

These 233 [supplemental declarations](supplemental-public-signatures.tsv) complement the 305 canonical native wrappers. Constructors and owner methods are also grouped with their type in [types](types.md). Every entry uses the public signature; private native fields are omitted. See [ownership contracts](CONTRACT-NOTES.md) for the owner, buffer, callback, and native worker rules, and [synchronization and native-carrier ownership](types.md#synchronization-and-native-carrier-ownership) for blocking synchronization, raw heap mutex/thread-token ownership, `once_t`/`key_t`, and cross-thread wake rules.

## Abandoned-loop retirement

```text
function loop_abandon(loop: loop_t): integer
```

Retire an exclusively owned loop during the final teardown of its Lua state; see
the complete [abandonment contract](../standard-library-uv.md#abandoned-loop-retirement).
It suppresses every user callback, waits for accepted native work, releases
undelivered request-owned results, and closes the loop. It returns zero for a
closed, fresh, or already closed loop, and `EBUSY` without changing anything
when called inside an active run, walk, or callback. It is not ordinary
shutdown or domain-resource cleanup.

## Native resource handoff

The following nine declarations implement the [native handoff contract](../standard-library-uv.md#native-resource-handoff):

```titan
function bind_transfer_loop(loop: loop_t)
function unbind_transfer_loop(loop: loop_t)
function stream_transfer_status(stream: stream_t, allow_reading: boolean?): integer
function tcp_t:to_transfer_payload(): string
function tcp_t.from_transfer_payload(payload: string): tcp_t
function pipe_t:to_transfer_payload(): string
function pipe_t.from_transfer_payload(payload: string): pipe_t
function tcp_t.discard_transfer_payload(payload: string): integer
function pipe_t.discard_transfer_payload(payload: string): integer
```

The state-local binding selects the destination loop. The read-only status
query rejects unsupported or pending operations. Encoding detaches one idle
endpoint; reconstruction adopts it once with fresh native storage. The caller
owns payload delivery, adoption, and recovery. Ordinary async programs use the
binding installed by their active Runtime. The explicit discard methods consume
a known unadopted byte payload without a loop and return native close status.
A close attempt consumes ownership even when it reports an error.


## Synchronization, native carriers, and external wake bridge

Native synchronization and cross-thread wake helpers follow the central rules in [types](types.md#synchronization-and-native-carrier-ownership) and the [threading reference](functions/threading.md):

- **Blocking OS primitives vs cooperative Tasks:** Lock/wait operations on `mutex_t`, `rwlock_t`, `sem_t`, `cond_t`, and `barrier_t` block the calling OS thread, not just an `async.Task`. Do not suspend a Task while holding a blocking `uv` mutex or lock. Use same-state [`async.channel`](../async-io.md#bounded-channels) or cross-thread [`thread.channel`](../standard-library-thread.md#cross-thread-channels) for cooperative coordination; there is no `thread.Mutex` API. Try operations, notifications, queries, and TLS access are not all blocking waits.
- **Checked GC-backed owners vs borrowed pointers:** `mutex_t`, `rwlock_t`, `sem_t`, `cond_t`, `barrier_t`, and `key_t` have explicit `Fresh -> Live -> Retired` lifetimes. Successful `init`/`create` makes an owner live; a negative result leaves it fresh. `destroy`/`delete` is terminal and must follow quiescence of every native user; GC supplies no automatic destruction. `:borrow()` requires a live owner and returns an unrooted `foreign *void`; keep the complete owner rooted until every worker or thread finishes, then retire it explicitly. The raw `native_*` calls bypass these checked lifecycle guards.
- **Process-heap mutexes:** [`mutex_t.create_native`](#mutex_tcreate_native) allocates and initializes an independent `uv_mutex_t` on the process heap outside GC. [`native_mutex_lock`](#native_mutex_lock), [`native_mutex_trylock`](#native_mutex_trylock), and [`native_mutex_unlock`](#native_mutex_unlock) accept either a `create_native` pointer or `mutex_t:borrow()`. [`native_mutex_destroy`](#native_mutex_destroy) both destroys and `free`s **only** `mutex_t.create_native()` pointers after quiescence (and is a no-op on `nil`); never pass `mutex_t:borrow()` to `native_mutex_destroy`.
- **`once_t` and `key_t`:** [`once_t.new`](#once_tnew) already initializes its guard in final stable storage (`UV_ONCE_INIT`); there is no separate initialization, destroy, or reset operation. Root it through every participating native call. [`once`](functions/threading.md#once) and [`native_once`](#native_once) take a non-null C-only `foreign function(): void` callback. `key_t` manages an OS-thread-local `foreign *void` slot, not `async.Task`-local state, pointee ownership, or a GC root; the caller retains and disposes pointees independently of key deletion.
- **Direct C-only `native_*` entries:** The [entry map below](#direct-synchronization-entry-map) accounts for all 20 removed synchronization getters and their exact direct C signatures: 18 newly public entries plus the already-public mutex lock/unlock entries. The separate heap-only `native_mutex_destroy` is unchanged. Unrelated [`async_send_function`](#async_send_function), [`async_send_native`](#async_send_native), [`thread_getcpu_function`](#thread_getcpu_function), and [`thread_setname_function`](#thread_setname_function) remain available.
- **Cross-thread external wake bridge:** [`external_wake_t.new`](#external_wake_tnew) constructs the owner; [`external_wake_init`](#external_wake_init) creates an unreferenced async handle and native queue. [`reserve`](#external_wake_treserve) only prepares storage and returns a borrowed target. [`activate`](#external_wake_tactivate) begins an actual wait and references the handle until that wait is unregistered, not merely until its notification is drained. C-only producers hold separate [`retain`](#native_external_wake_retain)/[`release`](#native_external_wake_release) references while calling [`notify`](#native_external_wake_notify). The destination drains bounded identity batches and retires targets with [`unregister`](#external_wake_tunregister) before normal [`close`](#external_wake_tclose), which returns `uv.EBUSY` even for an unused prepared registration. A nonyielding GC detach retires leftover registrations but is not a replacement for native close completion. See the [central wake lifetime rules](types.md#synchronization-and-native-carrier-ownership) and [extension guide](../../implementation/libuv-extension-guide.md#external-wake-bridge).
- **Caller-owned heap thread tokens:** [`create_native_thread`](#create_native_thread) starts a C-only worker and returns a process-heap token, without retaining any GC argument graph. [`native_thread_join`](#native_thread_join) and [`native_thread_detach`](#native_thread_detach) consume and free that token only on native success; a nonzero status preserves the same owner. Detach retires only the token and does not wait for worker completion. These helpers are distinct from the unchanged checked `thread_t`/`argument_owner` API.

### Direct synchronization entry map

The left column names removed getters, not callable aliases. Use the right-hand
entry directly through ordinary `import "uv"` and assign it to an exactly
compatible `foreign function` pointer when a native carrier needs a callback.
These are C signatures: `int` results are native C statuses/results, not Titan
`integer` result slots. The existing checked owner methods and canonical
functions remain available on the owning Lua thread.

| Removed getter | Direct public declaration |
| --- | --- |
| `mutex_t.lock_function` | `foreign function native_mutex_lock(native: *void): void` |
| `mutex_t.trylock_function` | `foreign function native_mutex_trylock(native: *void): int` |
| `mutex_t.unlock_function` | `foreign function native_mutex_unlock(native: *void): void` |
| `rwlock_t.rdlock_function` | `foreign function native_rwlock_rdlock(native: *void): void` |
| `rwlock_t.tryrdlock_function` | `foreign function native_rwlock_tryrdlock(native: *void): int` |
| `rwlock_t.rdunlock_function` | `foreign function native_rwlock_rdunlock(native: *void): void` |
| `rwlock_t.wrlock_function` | `foreign function native_rwlock_wrlock(native: *void): void` |
| `rwlock_t.trywrlock_function` | `foreign function native_rwlock_trywrlock(native: *void): int` |
| `rwlock_t.wrunlock_function` | `foreign function native_rwlock_wrunlock(native: *void): void` |
| `sem_t.post_function` | `foreign function native_sem_post(native: *void): void` |
| `sem_t.wait_function` | `foreign function native_sem_wait(native: *void): void` |
| `sem_t.trywait_function` | `foreign function native_sem_trywait(native: *void): int` |
| `cond_t.signal_function` | `foreign function native_cond_signal(native: *void): void` |
| `cond_t.broadcast_function` | `foreign function native_cond_broadcast(native: *void): void` |
| `cond_t.wait_function` | `foreign function native_cond_wait(cond: *void, mutex: *void): void` |
| `cond_t.timedwait_function` | `foreign function native_cond_timedwait(cond: *void, mutex: *void, timeout_ns: unsigned long long): int` |
| `barrier_t.wait_function` | `foreign function native_barrier_wait(native: *void): int` |
| `key_t.get_function` | `foreign function native_key_get(key: *void): *void` |
| `key_t.set_function` | `foreign function native_key_set(key: *void, value: *void): void` |
| `once_function` | `foreign function native_once(guard: *void, callback: function(): void): void` |

The timeout is a relative unsigned nanosecond interval. Condition waits require
the caller to hold the mutex, release it atomically while waiting, and reacquire
it before return; always recheck the protected predicate in a loop. Try
operations return `0` on acquisition/decrement or a negative native status.
Barrier wait returns a positive serial-thread result for one participant and
`0` for the others. The once callback has no arguments or return value and
must execute only C/native work.

[`native_mutex_destroy(native: *void): void`](#native_mutex_destroy) is not a
getter replacement: it destroys and frees only `mutex_t.create_native()` output
after quiescence and accepts NULL as a no-op. Borrowed storage instead retires
through its checked owner. Raw entries do not validate pointer kind or liveness;
using a stale or wrong-kind pointer is undefined behavior. C-only calls after
state close still require a mapped provider; runtime-loaded Titan DSOs follow
the [process-lifetime mapping rule](../../implementation/foreign-functions.md).


## addrinfo_result_t:entries

Return the cached or newly copied address entries in native resolver order. Call before `freeaddrinfo`; calling it on a released result raises. Already returned Arrays, strings, and address owners survive native release.

```titan
function addrinfo_result_t:entries(): {addrinfo_t}
```


## async_send_function

Return the C-only send entry for a borrowed initialized async handle. Obtain the pointer and retain its owner on the Lua thread before passing them to a native carrier; that carrier must stop sending before close can retire the owner.

```titan
function async_send_function(): foreign function (*void): int
```

Returns the native-safe opaque async-send entry for an already-C-only carrier. Obtain and retain its associated owner before native use; ordinary async_send remains a Lua-thread call.


## async_send_native

Notify a borrowed initialized `uv_async_t` handle directly from C or Titan without entering Lua. Retain the associated `async_t` owner across all native callers and stop sending before closing the handle.

```titan
foreign function async_send_native(handle: *void): int
```

**Roles:** handle: INPUT borrowed initialized native uv_async_t pointer; caller retains the associated owner across all native uses.


## async_t.new

Allocate a concrete handle owner without initializing its native lifetime. Its matching native init/spawn operation establishes any close obligation; owner views do not initialize it.

```titan
function async_t.new(): async_t
```


## async_t:as_handle_t

Return a tagged view of the same concrete owner. No native storage is copied or separately owned; the view retains the owner and shares its lifetime.

```titan
function async_t:as_handle_t(): handle_t
```


## async_t:borrow

Borrow an opaque pointer to stable native storage for a C-only carrier. Retain the Titan owner until all native uses end; the pointer alone does not root it. Initialize the native lifetime before use and never let it outlive destroy/close.

```titan
function async_t:borrow(): foreign *void
```


## barrier_t.new

Allocate stable native storage without initializing it. Call the matching init/create operation before use and explicitly destroy/delete only after every native user has stopped.

```titan
function barrier_t.new(): barrier_t
```


## barrier_t:borrow

Borrow an opaque pointer to stable native storage for a C-only carrier. Retain the Titan owner until all native uses end; the pointer alone does not root it. Initialize the native lifetime before use and never let it outlive destroy/close.

```titan
function barrier_t:borrow(): foreign *void
```


## barrier_t:destroy

Convenience method for [`barrier_destroy`](functions/threading.md#barrier_destroy) on this owner. It has the same native status, preconditions, blocking behavior, and explicit lifetime rules as that function.

```titan
function barrier_t:destroy()
```


## barrier_t:init

Convenience method for [`barrier_init`](functions/threading.md#barrier_init) on this owner. It has the same native status, preconditions, blocking behavior, and explicit lifetime rules as that function.

```titan
function barrier_t:init(count: integer): integer
```

**Roles:** count: INPUT integer value; checked native narrowing occurs before native ownership is accepted.


## barrier_t:wait

Convenience method for [`barrier_wait`](functions/threading.md#barrier_wait) on this owner. It has the same native status, preconditions, blocking behavior, and explicit lifetime rules as that function.

```titan
function barrier_t:wait(): integer
```


## buf_t.allocate

Allocate a writable byte buffer of `capacity` bytes. Capacity must be nonnegative; the returned owner keeps its storage alive. It acquires no external resource.

```titan
function buf_t.allocate(capacity: integer): buf_t
```

**Roles:** capacity: INPUT integer value; checked native narrowing occurs before native ownership is accepted.


## buf_t.from_string

Create a readonly view over the complete binary string. The view retains that immutable string; it is valid for native input but cannot be used as a native output buffer.

```titan
function buf_t.from_string(base: string): buf_t
```

**Roles:** base: INPUT immutable byte string retained by the returned readonly buffer view, including embedded NUL bytes; the borrow outlives this constructor call.


## buf_t:get

Read one byte as an integer in 0..255. `index` is 1-based and must lie within this view.

```titan
function buf_t:get(index: integer): integer
```

**Roles:** index: INPUT integer value; checked native narrowing occurs before native ownership is accepted.


## buf_t:is_writable

Report whether this view permits native or explicit byte writes; a string-backed view is readonly.

```titan
function buf_t:is_writable(): boolean
```


## buf_t:length

Return this view's byte length or capacity. This is not a NUL-terminated string length.

```titan
function buf_t:length(): integer
```


## buf_t:set

Write one byte in 0..255 at a 1-based index. The view must be writable and the index in bounds.

```titan
function buf_t:set(index: integer, byte: integer)
```

**Roles:** index: INPUT integer value; checked native narrowing occurs before native ownership is accepted.; byte: INPUT integer value; checked native narrowing occurs before native ownership is accepted.


## buf_t:slice

Create a retained subview starting at 1-based `first` with exactly `length` bytes. Bounds are checked and writability follows the parent; no native resource is acquired.

```titan
function buf_t:slice(first: integer, length: integer): buf_t
```

**Roles:** first: INPUT integer value; checked native narrowing occurs before native ownership is accepted.; length: INPUT integer value; checked native narrowing occurs before native ownership is accepted.


## buf_t:to_string

Copy the first `length` bytes into an independent binary Titan string. The length must fit the view; the copy survives later buffer reuse.

```titan
function buf_t:to_string(length: integer): string
```

**Roles:** length: INPUT integer value; checked native narrowing occurs before native ownership is accepted.


## check_t.new

Allocate a concrete handle owner without initializing its native lifetime. Its matching native init/spawn operation establishes any close obligation; owner views do not initialize it.

```titan
function check_t.new(): check_t
```


## check_t:as_handle_t

Return a tagged view of the same concrete owner. No native storage is copied or separately owned; the view retains the owner and shares its lifetime.

```titan
function check_t:as_handle_t(): handle_t
```


## cond_t.new

Allocate stable native storage without initializing it. Call the matching init/create operation before use and explicitly destroy/delete only after every native user has stopped.

```titan
function cond_t.new(): cond_t
```


## cond_t:borrow

Borrow an opaque pointer to stable native storage for a C-only carrier. Retain the Titan owner until all native uses end; the pointer alone does not root it. Initialize the native lifetime before use and never let it outlive destroy/close.

```titan
function cond_t:borrow(): foreign *void
```


## cond_t:broadcast

Convenience method for [`cond_broadcast`](functions/threading.md#cond_broadcast) on this owner. It has the same native status, preconditions, blocking behavior, and explicit lifetime rules as that function.

```titan
function cond_t:broadcast()
```


## cond_t:destroy

Convenience method for [`cond_destroy`](functions/threading.md#cond_destroy) on this owner. It has the same native status, preconditions, blocking behavior, and explicit lifetime rules as that function.

```titan
function cond_t:destroy()
```


## cond_t:init

Convenience method for [`cond_init`](functions/threading.md#cond_init) on this owner. It has the same native status, preconditions, blocking behavior, and explicit lifetime rules as that function.

```titan
function cond_t:init(): integer
```


## cond_t:signal

Convenience method for [`cond_signal`](functions/threading.md#cond_signal) on this owner. It has the same native status, preconditions, blocking behavior, and explicit lifetime rules as that function.

```titan
function cond_t:signal()
```


## cond_t:timedwait

Convenience method for [`cond_timedwait`](functions/threading.md#cond_timedwait) on this owner. It has the same native status, preconditions, blocking behavior, and explicit lifetime rules as that function.

```titan
function cond_t:timedwait(mutex: mutex_t, timeout_ns: foreign unsigned long long): integer
```

**Roles:** mutex: INPUT/OUTPUT initialized native synchronization owner; caller coordinates external native users and lifetime; destroy/delete only after quiescence.; timeout_ns: INPUT foreign unsigned long long value; checked native narrowing occurs before native ownership is accepted.


## cond_t:wait

Convenience method for [`cond_wait`](functions/threading.md#cond_wait) on this owner. It has the same native status, preconditions, blocking behavior, and explicit lifetime rules as that function.

```titan
function cond_t:wait(mutex: mutex_t)
```

**Roles:** mutex: INPUT/OUTPUT initialized native synchronization owner; caller coordinates external native users and lifetime; destroy/delete only after quiescence.


## connect_t.new

Allocate a fresh request owner without submitting work. It can have only one pending native operation; accepted work retains its inputs through completion. Filesystem requests additionally require `fs_req_cleanup` before reuse.

```titan
function connect_t.new(): connect_t
```


## connect_t:as_req_t

Return a tagged view of the same concrete owner. No native storage is copied or separately owned; the view retains the owner and shares its lifetime.

```titan
function connect_t:as_req_t(): req_t
```


## connect_t:handle

Return the retained stream/handle association for this request, or nil when none is recorded. The query does not submit work or transfer handle-close ownership.

```titan
function connect_t:handle(): stream_t?
```


## create_native_thread

Start a C-only native thread and return `(0, token)` with a uniquely caller-owned
process-heap token. A NULL `entry` returns `(uv.EINVAL, nil)`, allocation failure
returns `(uv.ENOMEM, nil)`, and native creation failure frees the unpublished
token and returns `(status, nil)`. The worker may start before this call returns;
prepare its complete native argument graph before submission.

```text
function create_native_thread(entry: foreign function(*void): void,
                              argument: foreign *void): (integer, foreign *void)
```

**Roles:** entry: INPUT non-null C-only worker entry; argument: INPUT borrowed
native pointer, possibly NULL, with manually managed complete backing storage;
token: OUTPUT uniquely caller-owned heap capability, not checked `thread_t` storage.

This ordinary Titan constructor runs on its calling Lua thread. The worker
executes only `entry(argument)` and must not enter that hosting Lua/Titan state
or inspect its GC owners. This route never retains `argument_owner`: the caller
keeps code, argument storage, and all reachable native resources valid until
worker completion. Retire the token exactly once with
[`native_thread_join`](#native_thread_join) or
[`native_thread_detach`](#native_thread_detach). Detach does not establish
completion or retire argument resources. Never raw-free the token or mix it
with the checked `thread_t` API.


## dir_t.new

Allocate an empty directory owner. A successful `fs_opendir` establishes the native directory lifetime, which must end with `fs_closedir`.

```titan
function dir_t.new(): dir_t
```


## external_wake_init

Initialize an [`external_wake_t`](types.md#external_wake_t) bridge on `loop` with an unreferenced (`uv_unref`) internal `async_t` handle and a reference-counted, mutex-protected native waiter queue. `callback` runs on the owning loop thread with `owner` when notifications arrive. Returns `0` on success or a negative libuv status (`uv.EINVAL`, `uv.ENOMEM`).

```titan
function external_wake_init(loop: loop_t, owner: external_wake_t, callback: function (external_wake_t): ()): integer
```

**Roles:** loop: INPUT initialized destination loop owner; owner: INPUT/OUTPUT fresh external_wake_t owner; callback: INPUT loop-thread notification callback.


## external_wake_t.new

Allocate a fresh `external_wake_t` owner without initializing its native loop handle or queue. Registering its GC finalizer provides only a non-yielding state-teardown (`lua_close`) fallback that detaches the native core without driving a loop; normal callers initialize with [`external_wake_init`](#external_wake_init), unregister all targets, and call [`external_wake_t:close`](#external_wake_tclose).

```titan
function external_wake_t.new(): external_wake_t
```


## external_wake_t:activate

Transition a reserved `PREPARED` target from [`external_wake_t:reserve`](#external_wake_treserve) to `ARMED` without allocating, increment the bridge's active-wait count, and reference (`uv_ref`) the underlying `async_t` handle when active waits transition from zero to one. Activate only when admitting the wait, before native waiter publication. The reference lasts through `PENDING` and `DELIVERED` until exact unregister, not just until notification or drain. Return `0` on success or `uv.EINVAL` if the bridge is uninitialized/closed or a live `target` is nil, belongs to another bridge, or is not `PREPARED`. Failed native registration or an immediate readiness recheck must retire the activated target.

```titan
function external_wake_t:activate(target: foreign *void): integer
```

**Roles:** target: INPUT/OUTPUT borrowed prepared target pointer returned by reserve; transitions to armed and references the handle while active waits remain.


## external_wake_t:close

Begin closing an initialized bridge once **every** target, including unused `PREPARED` targets, has been retired with [`external_wake_t:unregister`](#external_wake_tunregister). Return `uv.EBUSY` while any registration remains, or `0` after clearing the borrowed handle pointer under the core mutex and scheduling native close. Drive the destination loop through close completion. Retained producer targets remain valid native allocations but notifications return `uv.EINVAL` without touching the closing handle. Fresh or finalized owners return `0`; the nonyielding GC detach is a separate teardown fallback that retires registrations and does not drive or close the loop.

```titan
function external_wake_t:close(): integer
```


## external_wake_t:drain

Drain up to `capacity` pending identities from the FIFO into caller-owned `output` storage (`foreign *unsigned long long` with at least `capacity` slots), mark each target `DELIVERED`, and re-arm `uv_async_send` if entries remain. Return `(status, count)`; process `count` identities even if re-arming fails. Uninitialized/closed bridges, nil `output`, or zero `capacity` return `(uv.EINVAL, 0)`. One pending node per target bounds native queue storage independently of notification count; no Lua/Titan values cross this queue. Draining does not unregister a target or release its active-wait loop reference. The destination adapter validates live identity/epoch state and schedules continuations; it must not assume one callback per notification or resume Tasks reentrantly.

```titan
function external_wake_t:drain(output: foreign *unsigned long long, capacity: foreign unsigned int): (integer, foreign unsigned int)
```

**Roles:** output: OUTPUT caller-owned array of unsigned long long slots; capacity: INPUT maximum identities to copy in this batch.


## external_wake_t:reserve

Preallocate a `PREPARED` target for an opaque `foreign unsigned long long` identity without referencing the internal async handle; the target may reuse the storage of a target previously retired on the same core. Return `(0, target)` or `(status, nil)` (`uv.EINVAL` or `uv.ENOMEM`). `target` is borrowed from the destination bridge's registration reference until exact unregister or detach; the pointer is not a GC root or an independent owner, and storage reuse gives no protection against stale or dangling pointers. Before cross-thread publication, take a separate [`native_external_wake_retain`](#native_external_wake_retain) producer reference. Preparation alone does not admit a wait or keep the loop alive.

```titan
function external_wake_t:reserve(identity: foreign unsigned long long): (integer, foreign *void)
```

**Roles:** identity: INPUT opaque waiter identity delivered on drain; returned target: OUTPUT borrowed registration pointer; the loop handle remains unreferenced until activate.


## external_wake_t:unregister

Retire a `PREPARED`, `ARMED`, `PENDING`, or `DELIVERED` target from this bridge in $O(1)$ time. Unlink any pending entry, decrement active waits if activated (`uv_unref` at zero), and consume the registration reference. Clear the destination identity-map entry and borrowed pointer first: success may immediately free the target or keep its storage for a later reservation. A separately retained producer reference may outlive unregister and must eventually be released. Return `0`, or `uv.EINVAL` for nil, a live foreign-core target, or a live retired target. These checks do not make a dangling pointer or a second call using a freed borrow safe.

```titan
function external_wake_t:unregister(target: foreign *void): integer
```

**Roles:** target: INPUT/OUTPUT borrowed target pointer returned by reserve; consumes registration reference and unreferences when active waits reach zero.


## fs_event_t.new

Allocate a concrete handle owner without initializing its native lifetime. Its matching native init/spawn operation establishes any close obligation; owner views do not initialize it.

```titan
function fs_event_t.new(): fs_event_t
```


## fs_event_t:as_handle_t

Return a tagged view of the same concrete owner. No native storage is copied or separately owned; the view retains the owner and shares its lifetime.

```titan
function fs_event_t:as_handle_t(): handle_t
```


## fs_get_dir

Return the directory owner from a successfully completed `fs_opendir` request before request cleanup. The directory has its own `fs_closedir` obligation; `fs_req_cleanup` alone does not close it.

```titan
function fs_get_dir(request: fs_t): dir_t
```

Returns the separately owned open directory created by OPENDIR; fs_req_cleanup does not close it.

**Roles:** request: INPUT terminal request; result getters reject pending state; copy result before explicit fs_req_cleanup.


## fs_get_entries

Copy a completed successful `fs_readdir` result into independent directory-entry records. Call before `fs_req_cleanup`; the returned entries survive that cleanup.

```titan
function fs_get_entries(request: fs_t): {dirent_t}
```

Copies READDIR entries/names before request cleanup; the directory remains busy until cleanup.

**Roles:** request: INPUT terminal request; result getters reject pending state; copy result before explicit fs_req_cleanup.


## fs_get_loop

Return this request's retained loop association, or nil when none is recorded. It neither drives nor closes that loop.

```titan
function fs_get_loop(request: fs_t): loop_t?
```

Accepts an allocated fs_t before submission, while pending, after completion and after cleanup. Returns its retained loop association, or nil when no loop has been associated, including synchronous work submitted without a loop. This is an association query, not a completed-result getter; it does not require fs_req_cleanup.

**Roles:** request: INPUT allocated request owner/view, including fresh, pending or completed state; this is a data/type/association query, not a pending-result read or a new submission.


## fs_get_statfs

Copy the completed successful `fs_statfs` result before request cleanup. All copied fields and spare values survive cleanup.

```titan
function fs_get_statfs(request: fs_t): statfs_t
```

Copies statfs fields; rejects failed, pending or wrong-kind requests.

**Roles:** request: INPUT terminal request; result getters reject pending state; copy result before explicit fs_req_cleanup.


## fs_get_string

Copy a completed successful `fs_readlink` or `fs_realpath` result before request cleanup. Calling it for another result kind, a pending request, or a cleaned request raises.

```titan
function fs_get_string(request: fs_t): string
```

Copies READLINK/REALPATH output before cleanup; no native result pointer escapes.

**Roles:** request: INPUT terminal request; result getters reject pending state; copy result before explicit fs_req_cleanup.


## fs_poll_t.new

Allocate a concrete handle owner without initializing its native lifetime. Its matching native init/spawn operation establishes any close obligation; owner views do not initialize it.

```titan
function fs_poll_t.new(): fs_poll_t
```


## fs_poll_t:as_handle_t

Return a tagged view of the same concrete owner. No native storage is copied or separately owned; the view retains the owner and shares its lifetime.

```titan
function fs_poll_t:as_handle_t(): handle_t
```


## fs_t.new

Allocate a fresh request owner without submitting work. It can have only one pending native operation; accepted work retains its inputs through completion. Filesystem requests additionally require `fs_req_cleanup` before reuse.

```titan
function fs_t.new(): fs_t
```


## fs_t:as_req_t

Return a tagged view of the same concrete owner. No native storage is copied or separately owned; the view retains the owner and shares its lifetime.

```titan
function fs_t:as_req_t(): req_t
```


## getaddrinfo_t.new

Allocate a fresh request owner without submitting work. It can have only one pending native operation; accepted work retains its inputs through completion. Filesystem requests additionally require `fs_req_cleanup` before reuse.

```titan
function getaddrinfo_t.new(): getaddrinfo_t
```


## getaddrinfo_t:addrinfo

Return the retained native completion status and optional address-result owner. The result can require `freeaddrinfo` even when copying failed before the user callback; release is idempotent.

```titan
function getaddrinfo_t:addrinfo(): (integer, addrinfo_result_t?)
```


## getaddrinfo_t:as_req_t

Return a tagged view of the same concrete owner. No native storage is copied or separately owned; the view retains the owner and shares its lifetime.

```titan
function getaddrinfo_t:as_req_t(): req_t
```


## getaddrinfo_t:get_loop

Return the request's recorded loop association, or nil when none is recorded. This is the same loop owner, not a new loop or a driving operation.

```titan
function getaddrinfo_t:get_loop(): loop_t?
```


## getnameinfo_t.new

Allocate a fresh request owner without submitting work. It can have only one pending native operation; accepted work retains its inputs through completion. Filesystem requests additionally require `fs_req_cleanup` before reuse.

```titan
function getnameinfo_t.new(): getnameinfo_t
```


## getnameinfo_t:as_req_t

Return a tagged view of the same concrete owner. No native storage is copied or separately owned; the view retains the owner and shares its lifetime.

```titan
function getnameinfo_t:as_req_t(): req_t
```


## getnameinfo_t:get_loop

Return the request's recorded loop association, or nil when none is recorded. This is the same loop owner, not a new loop or a driving operation.

```titan
function getnameinfo_t:get_loop(): loop_t?
```


## getnameinfo_t:result

Return the saved status and copied hostname/service results. These ordinary strings do not borrow the callback's native text storage.

```titan
function getnameinfo_t:result(): (integer, string?, string?)
```


## handle_t:is_initialized

Report whether the concrete owner currently has an initialized native handle lifetime, including closing. Fresh or fully retired storage reports false. This is safe before deciding whether native handle queries are valid.

```titan
function handle_t:is_initialized(): boolean
```

True for the current initialized lifetime, including closing; false for fresh or retired storage. Use on a prebuilt view of a caller-owned fresh poll owner after a negative init result to decide whether native close is required. This is a query of the current lifetime: trailing cleanup must not close a replacement initialized by an earlier close callback. See the exact recipe in CONTRACT-NOTES.md.


## has_api

Return true only for an exported canonical native-wrapper name without the `uv_` prefix. Unknown names, direct omissions, internal free functions, and supplemental helper names return false; this does not probe OS/kernel support.

```titan
function has_api(name: string): boolean
```

Accepts a canonical public operation name without uv_; true means exported by this provider, not guaranteed successful on this OS/kernel. Proposed omissions and internal-only frees are false.

**Roles:** name: INPUT immutable text/byte owner; native C-string conventions apply where the operation takes text. FS path strings remain retained until request cleanup; other synchronous borrows end when the call returns.


## idle_t.new

Allocate a concrete handle owner without initializing its native lifetime. Its matching native init/spawn operation establishes any close obligation; owner views do not initialize it.

```titan
function idle_t.new(): idle_t
```


## idle_t:as_handle_t

Return a tagged view of the same concrete owner. No native storage is copied or separately owned; the view retains the owner and shares its lifetime.

```titan
function idle_t:as_handle_t(): handle_t
```


## key_t.new

Allocate stable native storage without initializing it. Call the matching init/create operation before use and explicitly destroy/delete only after every native user has stopped.

```titan
function key_t.new(): key_t
```


## key_t:borrow

Borrow an opaque pointer to stable native storage for a C-only carrier. Retain the Titan owner until all native uses end; the pointer alone does not root it. Initialize the native lifetime before use and never let it outlive destroy/close.

```titan
function key_t:borrow(): foreign *void
```


## key_t:create

Convenience method for [`key_create`](functions/threading.md#key_create) on this owner. It has the same native status, preconditions, blocking behavior, and explicit lifetime rules as that function.

```titan
function key_t:create(): integer
```


## key_t:delete

Convenience method for [`key_delete`](functions/threading.md#key_delete) on this owner. It has the same native status, preconditions, blocking behavior, and explicit lifetime rules as that function.

```titan
function key_t:delete()
```


## key_t:get

Convenience method for [`key_get`](functions/threading.md#key_get) on this owner. It has the same native status, preconditions, blocking behavior, and explicit lifetime rules as that function.

```titan
function key_t:get(): foreign *void
```


## key_t:set

Convenience method for [`key_set`](functions/threading.md#key_set) on this owner. It has the same native status, preconditions, blocking behavior, and explicit lifetime rules as that function.

```titan
function key_t:set(value: foreign *void)
```

**Roles:** value: INPUT borrowed native address for explicit C-only/TLS interop; no automatic GC ownership. Retain its complete backing graph using the associated owner parameter or external lifetime.


## lib_t.new

Allocate a fresh library owner for one open attempt. Even a failed native open may need `dlclose` to retire its error storage; closing is terminal for this owner.

```titan
function lib_t.new(): lib_t
```


## lib_t:dlclose

Convenience method for [`dlclose`](functions/dll.md#dlclose) on this owner. It has the same native status, preconditions, blocking behavior, and explicit lifetime rules as that function.

```titan
function lib_t:dlclose()
```


## lib_t:dlerror

Convenience method for [`dlerror`](functions/dll.md#dlerror) on this owner. It has the same native status, preconditions, blocking behavior, and explicit lifetime rules as that function.

```titan
function lib_t:dlerror(): string
```


## lib_t:dlopen

Convenience method for [`dlopen`](functions/dll.md#dlopen) on this owner. It has the same native status, preconditions, blocking behavior, and explicit lifetime rules as that function.

```titan
function lib_t:dlopen(filename: string): integer
```

**Roles:** filename: INPUT immutable text/byte owner; native C-string conventions apply where the operation takes text. FS path strings remain retained until request cleanup; other synchronous borrows end when the call returns.


## lib_t:dlsym

Convenience method for [`dlsym`](functions/dll.md#dlsym) on this owner. It has the same native status, preconditions, blocking behavior, and explicit lifetime rules as that function.

```titan
function lib_t:dlsym(name: string): (integer, symbol_t?)
```

**Roles:** name: INPUT immutable text/byte owner; native C-string conventions apply where the operation takes text. FS path strings remain retained until request cleanup; other synchronous borrows end when the call returns.


## loop_t.new

Allocate a loop owner without initializing native loop state. Call `loop_init`, retire all associated handles and requests, then call `loop_close`.

```titan
function loop_t.new(): loop_t
```


## loop_t:secondary_error_count

Return the number of later callback errors suppressed behind the first error at the native driver boundary. Driving resets this observation for the next run; the first original error and trace are the ones rethrown.

```titan
function loop_t:secondary_error_count(): integer
```


## mutex_t.create_native

Allocate and initialize a process-heap `uv_mutex_t` not owned by any Lua state's GC (returning `nil` if allocation or `uv_mutex_init` fails). Use [`native_mutex_lock`](#native_mutex_lock), [`native_mutex_trylock`](#native_mutex_trylock), and [`native_mutex_unlock`](#native_mutex_unlock) to operate on the returned pointer, and destroy and free it with [`native_mutex_destroy`](#native_mutex_destroy) only after all native users are quiescent.

```titan
function mutex_t.create_native(): foreign *void
```


## mutex_t.new

Allocate stable native storage without initializing it. Call the matching init/create operation before use and explicitly destroy/delete only after every native user has stopped.

```titan
function mutex_t.new(): mutex_t
```


## mutex_t:borrow

Borrow an opaque pointer to stable native storage for a C-only carrier. Retain the Titan owner until all native uses end; the pointer alone does not root it. Initialize the native lifetime before use and never let it outlive destroy/close.

```titan
function mutex_t:borrow(): foreign *void
```


## mutex_t:destroy

Convenience method for [`mutex_destroy`](functions/threading.md#mutex_destroy) on this owner. It has the same native status, preconditions, blocking behavior, and explicit lifetime rules as that function.

```titan
function mutex_t:destroy()
```


## mutex_t:init

Convenience method for [`mutex_init`](functions/threading.md#mutex_init) on this owner. It has the same native status, preconditions, blocking behavior, and explicit lifetime rules as that function.

```titan
function mutex_t:init(): integer
```


## mutex_t:init_recursive

Convenience method for [`mutex_init_recursive`](functions/threading.md#mutex_init_recursive) on this owner. It has the same native status, preconditions, blocking behavior, and explicit lifetime rules as that function.

```titan
function mutex_t:init_recursive(): integer
```


## mutex_t:lock

Convenience method for [`mutex_lock`](functions/threading.md#mutex_lock) on this owner. It has the same native status, preconditions, blocking behavior, and explicit lifetime rules as that function.

```titan
function mutex_t:lock()
```


## mutex_t:trylock

Convenience method for [`mutex_trylock`](functions/threading.md#mutex_trylock) on this owner. It has the same native status, preconditions, blocking behavior, and explicit lifetime rules as that function.

```titan
function mutex_t:trylock(): integer
```


## mutex_t:unlock

Convenience method for [`mutex_unlock`](functions/threading.md#mutex_unlock) on this owner. It has the same native status, preconditions, blocking behavior, and explicit lifetime rules as that function.

```titan
function mutex_t:unlock()
```


## native_barrier_wait

Block the calling OS thread at a borrowed initialized `uv_barrier_t` pointer directly from C or Titan until all configured participants arrive. Returns a positive serial-thread indicator (`> 0`) for one participant and `0` for all others (not a negative error status). Retain the associated `barrier_t` owner across all native callers.

```titan
foreign function native_barrier_wait(native: *void): int
```

**Roles:** native: INPUT/OUTPUT borrowed initialized uv_barrier_t pointer; caller retains the associated owner across all native uses.


## native_cond_broadcast

Wake all OS threads waiting on a borrowed initialized `uv_cond_t` pointer directly from C or Titan. Retain the associated `cond_t` owner across all native callers.

```titan
foreign function native_cond_broadcast(native: *void): void
```

**Roles:** native: INPUT/OUTPUT borrowed initialized uv_cond_t pointer; caller retains the associated owner across all native uses.


## native_cond_signal

Wake one OS thread waiting on a borrowed initialized `uv_cond_t` pointer directly from C or Titan. Retain the associated `cond_t` owner across all native callers.

```titan
foreign function native_cond_signal(native: *void): void
```

**Roles:** native: INPUT/OUTPUT borrowed initialized uv_cond_t pointer; caller retains the associated owner across all native uses.


## native_cond_timedwait

Atomically release a locked `mutex` (`mutex_t:borrow()` or `mutex_t.create_native()`) and wait on a borrowed initialized `cond` (`cond_t:borrow()`) with a relative `unsigned long long` nanosecond timeout directly from C or Titan, reacquiring `mutex` before returning. Returns `0` when signaled or a negative libuv status such as `uv.ETIMEDOUT`; recheck the caller's predicate in a loop because spurious wakeups are permitted.

```titan
foreign function native_cond_timedwait(cond: *void, mutex: *void, timeout_ns: unsigned long long): int
```

**Roles:** cond: INPUT/OUTPUT borrowed initialized uv_cond_t pointer; mutex: INPUT/OUTPUT locked borrowed or process-heap initialized uv_mutex_t pointer; timeout_ns: INPUT relative unsigned nanosecond timeout.


## native_cond_wait

Atomically release a locked `mutex` (`mutex_t:borrow()` or `mutex_t.create_native()`) and block the calling OS thread on a borrowed initialized `cond` (`cond_t:borrow()`) directly from C or Titan, reacquiring `mutex` before returning. Check the caller's predicate in a loop because spurious wakeups are permitted.

```titan
foreign function native_cond_wait(cond: *void, mutex: *void): void
```

**Roles:** cond: INPUT/OUTPUT borrowed initialized uv_cond_t pointer; mutex: INPUT/OUTPUT locked borrowed or process-heap initialized uv_mutex_t pointer.


## native_external_wake_is_notified

Return native `int` **1** when a valid target is `PENDING` or `DELIVERED`,
otherwise **0**, including NULL. The core mutex protects the phase snapshot.
Notification remains latched after drain until exact unregister or GC detach;
the query neither drains nor consumes the target, rearms it, or releases loop
liveness. This is a boolean result, not a negative-status channel.

```text
foreign function native_external_wake_is_notified(target: *void): int
```

**Roles:** target: INPUT target protected for the complete call by its valid
destination registration borrow or an independent native producer reference.

This C-only query may run on a foreign thread; it reads no Lua/Titan GC value.
A query does not acquire a reference or make a following access atomic with
retirement. Never query a freed borrow after unregister/detach; a surviving
retained reference may query the retired target and receives `0`.


## native_external_wake_notify

Notify an activated target directly from C or Titan while holding a producer reference for the entire call. An `ARMED` target is queued once and becomes `PENDING`; another `PENDING` notification repeats `uv_async_send` without adding a node. `DELIVERED` returns `0` without sending. Other accepted calls return the native send status. Queue publication precedes notification under the core mutex, so a negative send status does not retract the pending identity. NULL, `PREPARED`, `RETIRED`, or detached targets return `uv.EINVAL`; every non-NULL pointer must still have a valid reference. This entry accesses only native storage and never calls Lua.

```titan
foreign function native_external_wake_notify(target: *void): int
```

**Roles:** target: INPUT/OUTPUT retained activated external wake target pointer.


## native_external_wake_release

Release one native producer reference directly from C or Titan; NULL is a no-op. Once a target's last reference (its registration and every producer reference) is gone, the target retires: its storage is freed or kept for a later reservation on the same core. The core itself is freed once its owner reference and all of its targets are gone. Producer references may survive unregister, native close completion, or destination state teardown, but they neither retain Lua/Titan owners nor pin the provider image. Calls remain C-only and require the [provider to stay mapped](../../implementation/foreign-functions.md); a released pointer must not be reused, and storage reuse gives no protection against stale pointers.

```titan
foreign function native_external_wake_release(target: *void): void
```

**Roles:** target: INPUT/OUTPUT retained external wake target pointer, or NULL.


## native_external_wake_retain

Retain an additional native producer reference before publishing a reserved target to another OS thread; NULL is a no-op. Call only while an existing registration or producer reference still guarantees pointer validity. This pins the target and native core, not the destination bridge, handle, Lua state, or provider image. Pair each retain with exactly one release after all uses of that producer reference.

```titan
foreign function native_external_wake_retain(target: *void): void
```

**Roles:** target: INPUT/OUTPUT reserved external wake target pointer, or NULL.


## native_external_wake_unregister

Retire the target's destination registration directly through its native core,
with the same unlink/ref-count semantics as
[`external_wake_t:unregister`](#external_wake_tunregister). This C-ABI entry is
**destination-loop-thread-only**, not a producer-thread escape hatch: retirement
may call `uv_unref` on that loop's async handle.

```text
foreign function native_external_wake_unregister(target: *void): int
```

**Roles:** target: INPUT/OUTPUT valid registration borrow from `reserve`, or a
separately retained live target; success consumes the registration reference.

Clear destination identity-map entries and the registration borrow before
calling. Return `0` on retirement, or `uv.EINVAL` for NULL or an already-retired
target whose storage is still valid. A nonzero result does not consume a
registration. Success may immediately free a merely borrowed target or keep its
storage for a later reservation on the same core, so a consumed borrow may alias
a new target; never dereference it afterward. An independent producer reference
survives and still requires its matching release. Do not call both unregister
forms for one registration or mistake this operation for releasing a producer
reference.


## native_key_get

Read the calling OS thread's stored `foreign *void` value for a borrowed initialized `uv_key_t` pointer (`key_t:borrow()`) directly from C or Titan, returning NULL (`nil`) when unset. This is OS-thread-local pointer storage, not `async.Task`-local state or pointee ownership.

```titan
foreign function native_key_get(key: *void): *void
```

**Roles:** key: INPUT borrowed initialized uv_key_t pointer; caller retains the associated owner across all native uses.


## native_key_set

Set the calling OS thread's stored `foreign *void` value (or NULL) for a borrowed initialized `uv_key_t` pointer (`key_t:borrow()`) directly from C or Titan. The caller owns the pointee's lifetime across overwrite, thread exit, and `key_delete`.

```titan
foreign function native_key_set(key: *void, value: *void): void
```

**Roles:** key: INPUT borrowed initialized uv_key_t pointer; value: INPUT borrowed native address stored for the calling OS thread, or NULL.


## native_mutex_destroy

Destroy and free a process-heap mutex created with [`mutex_t.create_native`](#mutex_tcreate_native) after all native callers are quiescent. Passing NULL is a no-op. Never pass a borrowed [`mutex_t:borrow`](#mutex_tborrow) pointer to this function; GC-backed `mutex_t` owners use [`mutex_t:destroy`](#mutex_tdestroy) / [`mutex_destroy`](functions/threading.md#mutex_destroy).

```titan
foreign function native_mutex_destroy(native: *void): void
```

**Roles:** native: INPUT/OUTPUT process-heap mutex pointer from mutex_t.create_native, or NULL; destroys and frees after quiescence.


## native_mutex_lock

Block the calling OS thread until it acquires a borrowed (`mutex_t:borrow()`) or process-heap (`mutex_t.create_native()`) initialized `uv_mutex_t` pointer directly from C or Titan.

```titan
foreign function native_mutex_lock(native: *void): void
```

**Roles:** native: INPUT/OUTPUT borrowed or process-heap initialized uv_mutex_t pointer.


## native_mutex_trylock

Attempt immediate acquisition of a borrowed (`mutex_t:borrow()`) or process-heap (`mutex_t.create_native()`) initialized `uv_mutex_t` pointer directly from C or Titan. Returns `0` when acquired or a negative libuv status such as `uv.EBUSY`.

```titan
foreign function native_mutex_trylock(native: *void): int
```

**Roles:** native: INPUT/OUTPUT borrowed or process-heap initialized uv_mutex_t pointer.


## native_mutex_unlock

Unlock a borrowed (`mutex_t:borrow()`) or process-heap (`mutex_t.create_native()`) initialized `uv_mutex_t` pointer directly from C or Titan.

```titan
foreign function native_mutex_unlock(native: *void): void
```

**Roles:** native: INPUT/OUTPUT borrowed or process-heap initialized uv_mutex_t pointer.


## native_once

Run a non-null C-only no-argument initializer `callback` at most once for a borrowed `once_t` guard pointer (`once_t:borrow()`) directly from C or Titan. `once_t.new()` initializes its guard in final stable storage (`UV_ONCE_INIT`) with no destroy or reset operation; `callback` may run on whichever OS thread wins the race and must never enter Lua or Titan.

```titan
foreign function native_once(guard: *void, callback: function(): void): void
```

**Roles:** guard: INPUT/OUTPUT borrowed initialized uv_once_t pointer; callback: INPUT non-null C-only initializer with no arguments or return value.


## native_rwlock_rdlock

Acquire a shared read lock on a borrowed initialized `uv_rwlock_t` pointer (`rwlock_t:borrow()`) directly from C or Titan, blocking the calling OS thread if an exclusive writer holds the lock. Retain the `rwlock_t` owner across all native callers.

```titan
foreign function native_rwlock_rdlock(native: *void): void
```

**Roles:** native: INPUT/OUTPUT borrowed initialized uv_rwlock_t pointer; caller retains the associated owner across all native uses.


## native_rwlock_rdunlock

Release a shared read lock on a borrowed initialized `uv_rwlock_t` pointer (`rwlock_t:borrow()`) directly from C or Titan.

```titan
foreign function native_rwlock_rdunlock(native: *void): void
```

**Roles:** native: INPUT/OUTPUT borrowed initialized uv_rwlock_t pointer; caller retains the associated owner across all native uses.


## native_rwlock_tryrdlock

Attempt immediate shared read-lock acquisition on a borrowed initialized `uv_rwlock_t` pointer (`rwlock_t:borrow()`) directly from C or Titan. Returns `0` when acquired or a negative libuv status such as `uv.EBUSY`.

```titan
foreign function native_rwlock_tryrdlock(native: *void): int
```

**Roles:** native: INPUT/OUTPUT borrowed initialized uv_rwlock_t pointer; caller retains the associated owner across all native uses.


## native_rwlock_trywrlock

Attempt immediate exclusive write-lock acquisition on a borrowed initialized `uv_rwlock_t` pointer (`rwlock_t:borrow()`) directly from C or Titan. Returns `0` when acquired or a negative libuv status such as `uv.EBUSY`.

```titan
foreign function native_rwlock_trywrlock(native: *void): int
```

**Roles:** native: INPUT/OUTPUT borrowed initialized uv_rwlock_t pointer; caller retains the associated owner across all native uses.


## native_rwlock_wrlock

Acquire an exclusive write lock on a borrowed initialized `uv_rwlock_t` pointer (`rwlock_t:borrow()`) directly from C or Titan, blocking the calling OS thread until readers and writers release it. Retain the `rwlock_t` owner across all native callers.

```titan
foreign function native_rwlock_wrlock(native: *void): void
```

**Roles:** native: INPUT/OUTPUT borrowed initialized uv_rwlock_t pointer; caller retains the associated owner across all native uses.


## native_rwlock_wrunlock

Release an exclusive write lock on a borrowed initialized `uv_rwlock_t` pointer (`rwlock_t:borrow()`) directly from C or Titan.

```titan
foreign function native_rwlock_wrunlock(native: *void): void
```

**Roles:** native: INPUT/OUTPUT borrowed initialized uv_rwlock_t pointer; caller retains the associated owner across all native uses.


## native_sem_post

Increment a borrowed initialized `uv_sem_t` pointer (`sem_t:borrow()`) directly from C or Titan, waking one waiting OS thread when applicable. Retain the `sem_t` owner across all native callers.

```titan
foreign function native_sem_post(native: *void): void
```

**Roles:** native: INPUT/OUTPUT borrowed initialized uv_sem_t pointer; caller retains the associated owner across all native uses.


## native_sem_trywait

Attempt immediate decrement of a borrowed initialized `uv_sem_t` pointer (`sem_t:borrow()`) directly from C or Titan. Returns `0` when decremented or a negative libuv status such as `uv.EAGAIN`.

```titan
foreign function native_sem_trywait(native: *void): int
```

**Roles:** native: INPUT/OUTPUT borrowed initialized uv_sem_t pointer; caller retains the associated owner across all native uses.


## native_sem_wait

Block the calling OS thread until a borrowed initialized `uv_sem_t` pointer (`sem_t:borrow()`) can be decremented directly from C or Titan. Retain the `sem_t` owner across all native callers.

```titan
foreign function native_sem_wait(native: *void): void
```

**Roles:** native: INPUT/OUTPUT borrowed initialized uv_sem_t pointer; caller retains the associated owner across all native uses.


## native_thread_detach

Detach a live heap token returned by [`create_native_thread`](#create_native_thread).
Native success (`0`) consumes and frees the token; any nonzero status preserves
it for the same caller owner. NULL returns `uv.EINVAL`. Serialize token
retirement: no alias may join/detach a successfully consumed token.

```text
foreign function native_thread_detach(token: *void): int
```

Detach does **not** join the worker, free its argument, or establish that its
native resources are quiescent. Code and argument storage must remain valid
until independently established worker completion. The worker's native entry
and argument copies do not borrow token storage, so successful detach can free
the token while the worker is still running, including from the worker itself.
The entry is C-only and may run without Lua state, provided its provider remains
mapped. Never pass a checked `thread_t` owner or arbitrary thread identifier.


## native_thread_join

Join a live heap token returned by [`create_native_thread`](#create_native_thread),
blocking the calling OS thread until native worker completion. Success (`0`)
consumes and frees the token; a nonzero status preserves it for the same caller
owner. NULL returns `uv.EINVAL`. Serialize join/detach and never reuse an alias
after successful consumption.

```text
foreign function native_thread_join(token: *void): int
```

Do not hold a mutex needed by the worker across join or block a loop thread
whose progress the worker needs. The C-only call does not enter Lua or retire
argument resources itself; after successful join, their owner may dispose them
knowing the worker is finished. A failure is not completion evidence. Never
pass checked `thread_t` storage, a borrowed identity, or a raw-freed token.


## once_t.new

Allocate the guard already initialized with `UV_ONCE_INIT` in its final stable owner storage. Retain it through every participating native call; construction does not invoke the callback. There is no separate init, reset, or destroy operation.

```titan
function once_t.new(): once_t
```


## once_t:borrow

Borrow the guard already initialized by `once_t.new()` in final stable owner storage. The pointer does not root that owner; keep it rooted through all participating native calls, including contenders waiting for the initializer to finish. No additional init, reset, destroy, or close operation exists for `once_t`.

```titan
function once_t:borrow(): foreign *void
```


## os_fd_t.from_integer

Construct an exact-width native identifier token with checked integer conversion. This neither duplicates nor adopts the resource; collecting the token never closes it.

```titan
function os_fd_t.from_integer(identifier: integer): os_fd_t
```

**Roles:** identifier: INPUT integer value; checked native narrowing occurs before native ownership is accepted.


## os_fd_t:to_integer

Convert the exact-width native identifier to a Titan integer with checked representability. This is a borrowed identifier, not resource ownership.

```titan
function os_fd_t:to_integer(): integer
```


## os_sock_t.from_integer

Construct an exact-width native identifier token with checked integer conversion. This neither duplicates nor adopts the resource; collecting the token never closes it.

```titan
function os_sock_t.from_integer(socket: integer): os_sock_t
```

**Roles:** socket: INPUT integer value; checked native narrowing occurs before native ownership is accepted.


## os_sock_t:to_integer

Convert the exact-width native identifier to a Titan integer with checked representability. This is a borrowed identifier, not resource ownership.

```titan
function os_sock_t:to_integer(): integer
```


## pipe_t.new

Allocate a concrete handle owner without initializing its native lifetime. Its matching native init/spawn operation establishes any close obligation; owner views do not initialize it.

```titan
function pipe_t.new(): pipe_t
```


## pipe_t:as_handle_t

Return a tagged view of the same concrete owner. No native storage is copied or separately owned; the view retains the owner and shares its lifetime.

```titan
function pipe_t:as_handle_t(): handle_t
```


## pipe_t:as_stream_t

Return a tagged view of the same concrete owner. No native storage is copied or separately owned; the view retains the owner and shares its lifetime.

```titan
function pipe_t:as_stream_t(): stream_t
```


## pipe_t:ipc

Return the pipe owner's configured IPC mode. This query does not consume CREATE_PIPE eligibility.

```titan
function pipe_t:ipc(): integer
```


## poll_t.new

Allocate a concrete handle owner without initializing its native lifetime. Its matching native init/spawn operation establishes any close obligation; owner views do not initialize it.

```titan
function poll_t.new(): poll_t
```


## poll_t:as_handle_t

Return a tagged view of the same concrete owner. No native storage is copied or separately owned; the view retains the owner and shares its lifetime.

```titan
function poll_t:as_handle_t(): handle_t
```


## prepare_t.new

Allocate a concrete handle owner without initializing its native lifetime. Its matching native init/spawn operation establishes any close obligation; owner views do not initialize it.

```titan
function prepare_t.new(): prepare_t
```


## prepare_t:as_handle_t

Return a tagged view of the same concrete owner. No native storage is copied or separately owned; the view retains the owner and shares its lifetime.

```titan
function prepare_t:as_handle_t(): handle_t
```


## process_options_t.new

Create process options retaining the supplied executable text and argument Array. Other fields start with nil callbacks/env/cwd, zero flags/uid/gid, and empty stdio. This does not start a process.

```titan
function process_options_t.new(file: string, args: {string}): process_options_t
```

**Roles:** file: INPUT immutable text/byte owner; native C-string conventions apply where the operation takes text. FS path strings remain retained until request cleanup; other synchronous borrows end when the call returns.; args: INPUT immutable text/byte owner; native C-string conventions apply where the operation takes text. FS path strings remain retained until request cleanup; other synchronous borrows end when the call returns.


## process_t.new

Allocate a concrete handle owner without initializing its native lifetime. Its matching native init/spawn operation establishes any close obligation; owner views do not initialize it.

```titan
function process_t.new(): process_t
```


## process_t:as_handle_t

Return a tagged view of the same concrete owner. No native storage is copied or separately owned; the view retains the owner and shares its lifetime.

```titan
function process_t:as_handle_t(): handle_t
```


## random_t.new

Allocate a fresh request owner without submitting work. It can have only one pending native operation; accepted work retains its inputs through completion. Filesystem requests additionally require `fs_req_cleanup` before reuse.

```titan
function random_t.new(): random_t
```


## random_t:as_req_t

Return a tagged view of the same concrete owner. No native storage is copied or separately owned; the view retains the owner and shares its lifetime.

```titan
function random_t:as_req_t(): req_t
```


## req_t:get_data

Return this request's separate traced Titan data value, initially nil. The native `.data` slot remains reserved by the binding.

```titan
function req_t:get_data(): value
```


## req_t:set_data

Set the separate traced Titan data value; nil clears it. This does not alter request ownership, cancellation, or the reserved native `.data` slot.

```titan
function req_t:set_data(data: value)
```

**Roles:** data: INPUT traced public data, stored separately from reserved native .data; nil clears the value.


## rwlock_t.new

Allocate stable native storage without initializing it. Call the matching init/create operation before use and explicitly destroy/delete only after every native user has stopped.

```titan
function rwlock_t.new(): rwlock_t
```


## rwlock_t:borrow

Borrow an opaque pointer to stable native storage for a C-only carrier. Retain the Titan owner until all native uses end; the pointer alone does not root it. Initialize the native lifetime before use and never let it outlive destroy/close.

```titan
function rwlock_t:borrow(): foreign *void
```


## rwlock_t:destroy

Convenience method for [`rwlock_destroy`](functions/threading.md#rwlock_destroy) on this owner. It has the same native status, preconditions, blocking behavior, and explicit lifetime rules as that function.

```titan
function rwlock_t:destroy()
```


## rwlock_t:init

Convenience method for [`rwlock_init`](functions/threading.md#rwlock_init) on this owner. It has the same native status, preconditions, blocking behavior, and explicit lifetime rules as that function.

```titan
function rwlock_t:init(): integer
```


## rwlock_t:rdlock

Convenience method for [`rwlock_rdlock`](functions/threading.md#rwlock_rdlock) on this owner. It has the same native status, preconditions, blocking behavior, and explicit lifetime rules as that function.

```titan
function rwlock_t:rdlock()
```


## rwlock_t:rdunlock

Convenience method for [`rwlock_rdunlock`](functions/threading.md#rwlock_rdunlock) on this owner. It has the same native status, preconditions, blocking behavior, and explicit lifetime rules as that function.

```titan
function rwlock_t:rdunlock()
```


## rwlock_t:tryrdlock

Convenience method for [`rwlock_tryrdlock`](functions/threading.md#rwlock_tryrdlock) on this owner. It has the same native status, preconditions, blocking behavior, and explicit lifetime rules as that function.

```titan
function rwlock_t:tryrdlock(): integer
```


## rwlock_t:trywrlock

Convenience method for [`rwlock_trywrlock`](functions/threading.md#rwlock_trywrlock) on this owner. It has the same native status, preconditions, blocking behavior, and explicit lifetime rules as that function.

```titan
function rwlock_t:trywrlock(): integer
```


## rwlock_t:wrlock

Convenience method for [`rwlock_wrlock`](functions/threading.md#rwlock_wrlock) on this owner. It has the same native status, preconditions, blocking behavior, and explicit lifetime rules as that function.

```titan
function rwlock_t:wrlock()
```


## rwlock_t:wrunlock

Convenience method for [`rwlock_wrunlock`](functions/threading.md#rwlock_wrunlock) on this owner. It has the same native status, preconditions, blocking behavior, and explicit lifetime rules as that function.

```titan
function rwlock_t:wrunlock()
```


## sem_t.new

Allocate stable native storage without initializing it. Call the matching init/create operation before use and explicitly destroy/delete only after every native user has stopped.

```titan
function sem_t.new(): sem_t
```


## sem_t:borrow

Borrow an opaque pointer to stable native storage for a C-only carrier. Retain the Titan owner until all native uses end; the pointer alone does not root it. Initialize the native lifetime before use and never let it outlive destroy/close.

```titan
function sem_t:borrow(): foreign *void
```


## sem_t:destroy

Convenience method for [`sem_destroy`](functions/threading.md#sem_destroy) on this owner. It has the same native status, preconditions, blocking behavior, and explicit lifetime rules as that function.

```titan
function sem_t:destroy()
```


## sem_t:init

Convenience method for [`sem_init`](functions/threading.md#sem_init) on this owner. It has the same native status, preconditions, blocking behavior, and explicit lifetime rules as that function.

```titan
function sem_t:init(value: integer): integer
```

**Roles:** value: INPUT integer value; checked native narrowing occurs before native ownership is accepted.


## sem_t:post

Convenience method for [`sem_post`](functions/threading.md#sem_post) on this owner. It has the same native status, preconditions, blocking behavior, and explicit lifetime rules as that function.

```titan
function sem_t:post()
```


## sem_t:trywait

Convenience method for [`sem_trywait`](functions/threading.md#sem_trywait) on this owner. It has the same native status, preconditions, blocking behavior, and explicit lifetime rules as that function.

```titan
function sem_t:trywait(): integer
```


## sem_t:wait

Convenience method for [`sem_wait`](functions/threading.md#sem_wait) on this owner. It has the same native status, preconditions, blocking behavior, and explicit lifetime rules as that function.

```titan
function sem_t:wait()
```


## shutdown_t.new

Allocate a fresh request owner without submitting work. It can have only one pending native operation; accepted work retains its inputs through completion. Filesystem requests additionally require `fs_req_cleanup` before reuse.

```titan
function shutdown_t.new(): shutdown_t
```


## shutdown_t:as_req_t

Return a tagged view of the same concrete owner. No native storage is copied or separately owned; the view retains the owner and shares its lifetime.

```titan
function shutdown_t:as_req_t(): req_t
```


## shutdown_t:handle

Return the retained stream/handle association for this request, or nil when none is recorded. The query does not submit work or transfer handle-close ownership.

```titan
function shutdown_t:handle(): stream_t?
```


## signal_t.new

Allocate a concrete handle owner without initializing its native lifetime. Its matching native init/spawn operation establishes any close obligation; owner views do not initialize it.

```titan
function signal_t.new(): signal_t
```


## signal_t:as_handle_t

Return a tagged view of the same concrete owner. No native storage is copied or separately owned; the view retains the owner and shares its lifetime.

```titan
function signal_t:as_handle_t(): handle_t
```


## signal_t:get_signum

Return the signal number currently configured in the native signal owner. It does not start, stop, or close the watcher.

```titan
function signal_t:get_signum(): integer
```

Returns the native configured signal number while the handle is initialized; rejects fresh/retired storage. Stop resets it to zero. Oneshot native delivery resets after callback return, so the callback still observes the delivered signal number.


## sockaddr_t:address_bytes

Copy the 4 IPv4 or 16 IPv6 address bytes, excluding port and other sockaddr fields. Non-IP families raise.

```titan
function sockaddr_t:address_bytes(): string
```


## sockaddr_t:byte_length

Return the known native sockaddr byte length. Zero marks an incomplete family-only result.

```titan
function sockaddr_t:byte_length(): integer
```


## sockaddr_t:family

Return the native address-family integer, including on an incomplete family-only result.

```titan
function sockaddr_t:family(): integer
```


## sockaddr_t:flowinfo

Return the IPv6 flow-info field in its native numeric representation; non-IPv6 addresses return zero.

```titan
function sockaddr_t:flowinfo(): integer
```


## sockaddr_t:is_complete

Report whether complete native address bytes are available. A nonnull native address with unknown family may be represented only by its family.

```titan
function sockaddr_t:is_complete(): boolean
```


## sockaddr_t:port

Return an IPv4/IPv6 port in host numeric order. Non-IP families raise.

```titan
function sockaddr_t:port(): integer
```


## sockaddr_t:raw_bytes

Copy all known native sockaddr bytes, including native layout/padding; return nil for an incomplete address. These bytes are platform representation, not a portable serialization.

```titan
function sockaddr_t:raw_bytes(): string?
```


## sockaddr_t:sa_len

Return the platform sockaddr length field when present, otherwise nil. This does not change the independently recorded byte_length.

```titan
function sockaddr_t:sa_len(): integer?
```


## sockaddr_t:scope_id

Return the IPv6 scope identifier; non-IPv6 addresses return zero.

```titan
function sockaddr_t:scope_id(): integer
```


## sockaddr_t:set_flowinfo

Set the native uint32 IPv6 flow-info field with checked conversion. Non-IPv6 addresses raise.

```titan
function sockaddr_t:set_flowinfo(value: integer)
```

**Roles:** value: INPUT integer value; checked native narrowing occurs before native ownership is accepted.


## sockaddr_t:set_scope_id

Set the native uint32 IPv6 scope identifier with checked conversion. Non-IPv6 addresses raise.

```titan
function sockaddr_t:set_scope_id(value: integer)
```

**Roles:** value: INPUT integer value; checked native narrowing occurs before native ownership is accepted.


## stream_t:as_handle_t

Return a tagged view of the same concrete owner. No native storage is copied or separately owned; the view retains the owner and shares its lifetime.

```titan
function stream_t:as_handle_t(): handle_t
```


## symbol_t:library

Return the retained library owner associated with this symbol. This does not reopen or extend the native open lifetime after explicit close.

```titan
function symbol_t:library(): lib_t
```


## symbol_t:pointer

Return the borrowed native symbol address only while its library is open. A successful symbol may have a null address; the symbol owner, not pointer truthiness, records lookup success. Explicit library close invalidates native use.

```titan
function symbol_t:pointer(): foreign *void
```


## tcp_t.new

Allocate a concrete handle owner without initializing its native lifetime. Its matching native init/spawn operation establishes any close obligation; owner views do not initialize it.

```titan
function tcp_t.new(): tcp_t
```


## tcp_t:as_handle_t

Return a tagged view of the same concrete owner. No native storage is copied or separately owned; the view retains the owner and shares its lifetime.

```titan
function tcp_t:as_handle_t(): handle_t
```


## tcp_t:as_stream_t

Return a tagged view of the same concrete owner. No native storage is copied or separately owned; the view retains the owner and shares its lifetime.

```titan
function tcp_t:as_stream_t(): stream_t
```


## thread_getcpu_function

Return the C-only native entry for current CPU lookup. Obtain it on the Lua thread; foreign callers must obey the native argument lifetime and must not call ordinary Titan wrappers.

```titan
function thread_getcpu_function(): foreign function(): int
```

Returns the native C-only current-worker query entry; it does not make ordinary Titan calls safe on a worker.


## thread_setname_function

Return the C-only native entry for setting the calling native thread's name. Obtain it on the Lua thread; foreign callers must obey the native argument lifetime and must not call ordinary Titan wrappers.

```titan
function thread_setname_function(): foreign function(const *char): int
```

Returns a native C-only naming entry; keep C string storage valid through its synchronous use.


## thread_t.new

Allocate thread-token storage. This does not start a thread; creation and join/detach have separate native lifetimes.

```titan
function thread_t.new(): thread_t
```


## thread_t:create

Convenience method for [`thread_create`](functions/threading.md#thread_create) on this owner. It has the same native status, preconditions, blocking behavior, and explicit lifetime rules as that function.

```titan
function thread_t:create(entry: foreign function(*void): void, argument: foreign *void, argument_owner: value): integer
```

**Roles:** entry: INPUT C-only entry; no Lua/Titan execution from a native worker/once callback. Keep code loaded for every invocation.; argument: INPUT borrowed native address for explicit C-only/TLS interop; no automatic GC ownership. Retain its complete backing graph using the associated owner parameter or external lifetime.; argument_owner: INPUT traced argument-owner graph retained through native worker completion/join.


## thread_t:create_ex

Convenience method for [`thread_create_ex`](functions/threading.md#thread_create_ex) on this owner. It has the same native status, preconditions, blocking behavior, and explicit lifetime rules as that function.

```titan
function thread_t:create_ex(options: thread_options_t, entry: foreign function(*void): void, argument: foreign *void, argument_owner: value): integer
```

**Roles:** options: INPUT thread_options_t value; checked native narrowing occurs before native ownership is accepted.; entry: INPUT C-only entry; no Lua/Titan execution from a native worker/once callback. Keep code loaded for every invocation.; argument: INPUT borrowed native address for explicit C-only/TLS interop; no automatic GC ownership. Retain its complete backing graph using the associated owner parameter or external lifetime.; argument_owner: INPUT traced argument-owner graph retained through native worker completion/join.


## thread_t:detach

Convenience method for [`thread_detach`](functions/threading.md#thread_detach) on this owner. It has the same native status, preconditions, blocking behavior, and explicit lifetime rules as that function.

```titan
function thread_t:detach(): integer
```


## thread_t:equal

Convenience method for [`thread_equal`](functions/threading.md#thread_equal) on this owner. It has the same native status, preconditions, blocking behavior, and explicit lifetime rules as that function.

```titan
function thread_t:equal(other: thread_t): boolean
```

**Roles:** other: INPUT/OUTPUT thread identifier owner; create requires fresh/retired owner, join retains argument graph until completion, detach requires argument_owner=nil; thread_self returns a borrowed identity.


## thread_t:getaffinity

Convenience method for [`thread_getaffinity`](functions/threading.md#thread_getaffinity) on this owner. It has the same native status, preconditions, blocking behavior, and explicit lifetime rules as that function.

```titan
function thread_t:getaffinity(mask: owned char[]): integer
```

**Roles:** mask: OUTPUT owned byte array; capacity is its Array length, retained by caller through native operation.


## thread_t:getname

Convenience method for [`thread_getname`](functions/threading.md#thread_getname) on this owner. It has the same native status, preconditions, blocking behavior, and explicit lifetime rules as that function.

```titan
function thread_t:getname(capacity: integer): (integer, string?)
```

**Roles:** capacity: INPUT integer value; checked native narrowing occurs before native ownership is accepted.


## thread_t:getpriority

Convenience method for [`thread_getpriority`](functions/threading.md#thread_getpriority) on this owner. It has the same native status, preconditions, blocking behavior, and explicit lifetime rules as that function.

```titan
function thread_t:getpriority(): (integer, integer?)
```


## thread_t:join

Convenience method for [`thread_join`](functions/threading.md#thread_join) on this owner. It has the same native status, preconditions, blocking behavior, and explicit lifetime rules as that function.

```titan
function thread_t:join(): integer
```


## thread_t:setaffinity

Convenience method for [`thread_setaffinity`](functions/threading.md#thread_setaffinity) on this owner. It has the same native status, preconditions, blocking behavior, and explicit lifetime rules as that function.

```titan
function thread_t:setaffinity(mask: owned char[], oldmask: (owned char[])?): integer
```

**Roles:** mask: INPUT owned byte array; capacity is its Array length, retained by caller through native operation.; oldmask: OUTPUT owned byte array; capacity is its Array length, retained by caller through native operation. Optional nil is meaningful; see contract.


## thread_t:setpriority

Convenience method for [`thread_setpriority`](functions/threading.md#thread_setpriority) on this owner. It has the same native status, preconditions, blocking behavior, and explicit lifetime rules as that function.

```titan
function thread_t:setpriority(priority: integer): integer
```

**Roles:** priority: INPUT integer value; checked native narrowing occurs before native ownership is accepted.


## timer_t.new

Allocate a concrete handle owner without initializing its native lifetime. Its matching native init/spawn operation establishes any close obligation; owner views do not initialize it.

```titan
function timer_t.new(): timer_t
```


## timer_t:as_handle_t

Return a tagged view of the same concrete owner. No native storage is copied or separately owned; the view retains the owner and shares its lifetime.

```titan
function timer_t:as_handle_t(): handle_t
```


## tty_t.new

Allocate a concrete handle owner without initializing its native lifetime. Its matching native init/spawn operation establishes any close obligation; owner views do not initialize it.

```titan
function tty_t.new(): tty_t
```


## tty_t:as_handle_t

Return a tagged view of the same concrete owner. No native storage is copied or separately owned; the view retains the owner and shares its lifetime.

```titan
function tty_t:as_handle_t(): handle_t
```


## tty_t:as_stream_t

Return a tagged view of the same concrete owner. No native storage is copied or separately owned; the view retains the owner and shares its lifetime.

```titan
function tty_t:as_stream_t(): stream_t
```


## udp_send_t.new

Allocate a fresh request owner without submitting work. It can have only one pending native operation; accepted work retains its inputs through completion. Filesystem requests additionally require `fs_req_cleanup` before reuse.

```titan
function udp_send_t.new(): udp_send_t
```


## udp_send_t:as_req_t

Return a tagged view of the same concrete owner. No native storage is copied or separately owned; the view retains the owner and shares its lifetime.

```titan
function udp_send_t:as_req_t(): req_t
```


## udp_send_t:get_handle

Return the retained stream/handle association for this request, or nil when none is recorded. The query does not submit work or transfer handle-close ownership.

```titan
function udp_send_t:get_handle(): udp_t?
```


## udp_t.new

Allocate a concrete handle owner without initializing its native lifetime. Its matching native init/spawn operation establishes any close obligation; owner views do not initialize it.

```titan
function udp_t.new(): udp_t
```


## udp_t:as_handle_t

Return a tagged view of the same concrete owner. No native storage is copied or separately owned; the view retains the owner and shares its lifetime.

```titan
function udp_t:as_handle_t(): handle_t
```


## work_t.new

Allocate a fresh request owner without submitting work. It can have only one pending native operation; accepted work retains its inputs through completion. Filesystem requests additionally require `fs_req_cleanup` before reuse.

```titan
function work_t.new(): work_t
```


## work_t:as_req_t

Return a tagged view of the same concrete owner. No native storage is copied or separately owned; the view retains the owner and shares its lifetime.

```titan
function work_t:as_req_t(): req_t
```


## work_t:get_loop

Return the request's retained loop association, or nil when none is recorded. It neither drives nor closes the loop.

```titan
function work_t:get_loop(): loop_t?
```

Returns the last accepted loop association, retained after work completion. A subsequent accepted submission replaces it; immediate rejection restores the prior association. A fresh owner returns nil.


## write_t.new

Allocate a fresh request owner without submitting work. It can have only one pending native operation; accepted work retains its inputs through completion. Filesystem requests additionally require `fs_req_cleanup` before reuse.

```titan
function write_t.new(): write_t
```


## write_t:as_req_t

Return a tagged view of the same concrete owner. No native storage is copied or separately owned; the view retains the owner and shares its lifetime.

```titan
function write_t:as_req_t(): req_t
```


## write_t:handle

Return the retained stream/handle association for this request, or nil when none is recorded. The query does not submit work or transfer handle-close ownership.

```titan
function write_t:handle(): stream_t?
```


## write_t:send_handle

Return the retained handle transferred by a write2 request, or nil for a request without one. This is an owner view, not a new handle or independent close obligation.

```titan
function write_t:send_handle(): handle_t?
```


## setup_process_args

Use only the generated entrypoint's original argc/argv storage for one-time native argument/title setup. Returns true for a compiled Titan entrypoint and false for an ordinary Lua host; repeated supported calls are idempotent. It creates no loop or Runtime and applies no SIGPIPE policy.

```titan
function setup_process_args(): boolean
```

Configures libuv's process-argument/title support from the original argc/argv
saved by Titan's generated executable entrypoint. Returns true after successful
setup and on every later call. A Lua host has no such entrypoint arguments, so
it returns false without fabricating them. This does not create an async Runtime,
change SIGPIPE policy, or drive a loop. It may raise if the Lua stack cannot be
reserved for the registry handoff.

Call this before using process-title support in a low-level standalone program.
The `async` module calls it during initialization; `os.exepath` also ensures it
has run. Native setup may replace argv, and the generated entrypoint uses that
replacement when constructing main's Titan argument Array. `--no-uv-bootstrap`
skips Task wrapping of main, not module initialization or argument setup.

This safe helper does not accept an arbitrary Array of strings and does not
export native `uv_setup_args`. See [the process setup omission](functions/misc.md#setup_args).


## timer_close

Close the concrete timer with a direct timer callback. See [timer data and close](functions/timer.md#concrete-timer-data-and-close) for lifetime, errors, and callback-time reinitialization.

```titan
function timer_close(timer: timer_t, callback: timer_cb?)
```


## timer_get_data

Read the same traced public data as the generic handle accessor without allocating a handle view. Native data remains reserved by UV.

```titan
function timer_get_data(timer: timer_t): value
```


## timer_set_data

Replace the traced public data slot without allocating a handle view. Data remains accessible after close; native data remains reserved by UV.

```titan
function timer_set_data(timer: timer_t, data: value)
```


## write_string

Write one complete immutable binary string, using an embedded descriptor and retaining the old string through the native callback even when the request is reused. See [scalar string writes](functions/stream.md#write_string) for bounds and rejection rules.

```titan
function write_string(req: write_t, stream: stream_t, data: string, callback: write_cb?): integer
```


## write_t:get_data

Read the same traced public data as the generic request accessor without allocating a request view.

```titan
function write_t:get_data(): value
```


## write_t:set_data

Replace the traced public data slot without allocating a request view. This does not change reserved native data or pending-request ownership.

```titan
function write_t:set_data(data: value)
```


## buf_check_length

Validate the exact `buf_init` string/native byte-count bounds without allocating a buffer. Invalid input raises `"buffer length is outside string/native range"`. Adapters may validate before async admission.

```titan
function buf_check_length(base: string, length: integer)
```


## connect_t:get_data

Read the same traced public data as the generic request accessor without allocating a request view. The initial value is nil; fresh, pending and completed owners share the same slot.

```titan
function connect_t:get_data(): value
```


## connect_t:set_data

Replace the existing traced public data slot; nil clears it. This does not change reserved native data or pending-request ownership. See [concrete request data](functions/request.md#concrete-request-data).

```titan
function connect_t:set_data(data: value)
```


## fs_t:get_data

Read the same traced public data as the generic request accessor without allocating a request view. The initial value is nil; fresh, pending and completed owners share the same slot.

```titan
function fs_t:get_data(): value
```


## fs_t:set_data

Replace the existing traced public data slot; nil clears it. This does not change reserved native data or pending-request ownership. See [concrete request data](functions/request.md#concrete-request-data).

```titan
function fs_t:set_data(data: value)
```


## getaddrinfo_t:get_data

Read the same traced public data as the generic request accessor without allocating a request view. The initial value is nil; fresh, pending and completed owners share the same slot.

```titan
function getaddrinfo_t:get_data(): value
```


## getaddrinfo_t:set_data

Replace the existing traced public data slot; nil clears it. This does not change reserved native data or pending-request ownership. See [concrete request data](functions/request.md#concrete-request-data).

```titan
function getaddrinfo_t:set_data(data: value)
```


## shutdown_t:get_data

Read the same traced public data as the generic request accessor without allocating a request view. The initial value is nil; fresh, pending and completed owners share the same slot.

```titan
function shutdown_t:get_data(): value
```


## shutdown_t:set_data

Replace the existing traced public data slot; nil clears it. This does not change reserved native data or pending-request ownership. See [concrete request data](functions/request.md#concrete-request-data).

```titan
function shutdown_t:set_data(data: value)
```


## work_t:get_data

Read the same traced public data as the generic request accessor without allocating a request view. The initial value is nil; fresh, pending and completed owners share the same slot.

```titan
function work_t:get_data(): value
```


## work_t:set_data

Replace the existing traced public data slot; nil clears it. This does not change reserved native data or pending-request ownership. See [concrete request data](functions/request.md#concrete-request-data).

```titan
function work_t:set_data(data: value)
```
