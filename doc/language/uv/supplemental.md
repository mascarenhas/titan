# Supplemental public API reference

These 205 declarations complement the 305 canonical native wrappers. Constructors and owner methods are also grouped with their type in [types](types.md). Every entry uses the public signature; private native fields are omitted. See [ownership contracts](CONTRACT-NOTES.md) for the owner, buffer, callback, and native worker rules.

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


## barrier_t.wait_function

Return the exact C-only native entry for this operation. Obtain this pointer and retain borrowed owners before starting native work. Foreign calls obey native synchronization/lifetime rules and cannot enter Titan or Lua.

```titan
function barrier_t.wait_function(): foreign function(*void): int
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


## cond_t.broadcast_function

Return the exact C-only native entry for this operation. Obtain this pointer and retain borrowed owners before starting native work. Foreign calls obey native synchronization/lifetime rules and cannot enter Titan or Lua.

```titan
function cond_t.broadcast_function(): foreign function(*void): void
```


## cond_t.new

Allocate stable native storage without initializing it. Call the matching init/create operation before use and explicitly destroy/delete only after every native user has stopped.

```titan
function cond_t.new(): cond_t
```


## cond_t.signal_function

Return the exact C-only native entry for this operation. Obtain this pointer and retain borrowed owners before starting native work. Foreign calls obey native synchronization/lifetime rules and cannot enter Titan or Lua.

```titan
function cond_t.signal_function(): foreign function(*void): void
```


## cond_t.timedwait_function

Return the exact C-only native entry for this operation. Obtain this pointer and retain borrowed owners before starting native work. Foreign calls obey native synchronization/lifetime rules and cannot enter Titan or Lua.

```titan
function cond_t.timedwait_function(): foreign function(*void, *void, unsigned long long): int
```


## cond_t.wait_function

Return the exact C-only native entry for this operation. Obtain this pointer and retain borrowed owners before starting native work. Foreign calls obey native synchronization/lifetime rules and cannot enter Titan or Lua.

```titan
function cond_t.wait_function(): foreign function(*void, *void): void
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


## dir_t.new

Allocate an empty directory owner. A successful `fs_opendir` establishes the native directory lifetime, which must end with `fs_closedir`.

```titan
function dir_t.new(): dir_t
```


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


## key_t.get_function

Return the exact C-only native entry for this operation. Obtain this pointer and retain borrowed owners before starting native work. Foreign calls obey native synchronization/lifetime rules and cannot enter Titan or Lua.

```titan
function key_t.get_function(): foreign function(*void): *void
```


## key_t.new

Allocate stable native storage without initializing it. Call the matching init/create operation before use and explicitly destroy/delete only after every native user has stopped.

```titan
function key_t.new(): key_t
```


## key_t.set_function

Return the exact C-only native entry for this operation. Obtain this pointer and retain borrowed owners before starting native work. Foreign calls obey native synchronization/lifetime rules and cannot enter Titan or Lua.

```titan
function key_t.set_function(): foreign function(*void, *void): void
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


## mutex_t.lock_function

Return the exact C-only native entry for this operation. Obtain this pointer and retain borrowed owners before starting native work. Foreign calls obey native synchronization/lifetime rules and cannot enter Titan or Lua.

```titan
function mutex_t.lock_function(): foreign function(*void): void
```


## mutex_t.new

Allocate stable native storage without initializing it. Call the matching init/create operation before use and explicitly destroy/delete only after every native user has stopped.

```titan
function mutex_t.new(): mutex_t
```


## mutex_t.trylock_function

Return the exact C-only native entry for this operation. Obtain this pointer and retain borrowed owners before starting native work. Foreign calls obey native synchronization/lifetime rules and cannot enter Titan or Lua.

```titan
function mutex_t.trylock_function(): foreign function(*void): int
```


## mutex_t.unlock_function

Return the exact C-only native entry for this operation. Obtain this pointer and retain borrowed owners before starting native work. Foreign calls obey native synchronization/lifetime rules and cannot enter Titan or Lua.

```titan
function mutex_t.unlock_function(): foreign function(*void): void
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


## once_function

Return the C-only native once entry. The once owner and callback arguments must outlive every participating native call; the callback cannot access Titan or Lua.

```titan
function once_function(): foreign function(*void, function(): void): void
```

Returns a native-safe structural entry taking an opaque once guard and a no-argument C callback. Initialize once_t with the native initializer, retain it through all callers, and never invoke Lua/Titan from that callback.


## once_t.new

Allocate stable native once storage with its initial once state. Retain it across all participating native callers; construction does not invoke the callback.

```titan
function once_t.new(): once_t
```


## once_t:borrow

Borrow an opaque pointer to stable native storage for a C-only carrier. Retain the Titan owner until all native uses end; the pointer alone does not root it. Initialize the native lifetime before use and never let it outlive destroy/close.

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


## rwlock_t.rdlock_function

Return the exact C-only native entry for this operation. Obtain this pointer and retain borrowed owners before starting native work. Foreign calls obey native synchronization/lifetime rules and cannot enter Titan or Lua.

```titan
function rwlock_t.rdlock_function(): foreign function(*void): void
```


## rwlock_t.rdunlock_function

Return the exact C-only native entry for this operation. Obtain this pointer and retain borrowed owners before starting native work. Foreign calls obey native synchronization/lifetime rules and cannot enter Titan or Lua.

```titan
function rwlock_t.rdunlock_function(): foreign function(*void): void
```


## rwlock_t.tryrdlock_function

Return the exact C-only native entry for this operation. Obtain this pointer and retain borrowed owners before starting native work. Foreign calls obey native synchronization/lifetime rules and cannot enter Titan or Lua.

```titan
function rwlock_t.tryrdlock_function(): foreign function(*void): int
```


## rwlock_t.trywrlock_function

Return the exact C-only native entry for this operation. Obtain this pointer and retain borrowed owners before starting native work. Foreign calls obey native synchronization/lifetime rules and cannot enter Titan or Lua.

```titan
function rwlock_t.trywrlock_function(): foreign function(*void): int
```


## rwlock_t.wrlock_function

Return the exact C-only native entry for this operation. Obtain this pointer and retain borrowed owners before starting native work. Foreign calls obey native synchronization/lifetime rules and cannot enter Titan or Lua.

```titan
function rwlock_t.wrlock_function(): foreign function(*void): void
```


## rwlock_t.wrunlock_function

Return the exact C-only native entry for this operation. Obtain this pointer and retain borrowed owners before starting native work. Foreign calls obey native synchronization/lifetime rules and cannot enter Titan or Lua.

```titan
function rwlock_t.wrunlock_function(): foreign function(*void): void
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


## sem_t.post_function

Return the exact C-only native entry for this operation. Obtain this pointer and retain borrowed owners before starting native work. Foreign calls obey native synchronization/lifetime rules and cannot enter Titan or Lua.

```titan
function sem_t.post_function(): foreign function(*void): void
```


## sem_t.trywait_function

Return the exact C-only native entry for this operation. Obtain this pointer and retain borrowed owners before starting native work. Foreign calls obey native synchronization/lifetime rules and cannot enter Titan or Lua.

```titan
function sem_t.trywait_function(): foreign function(*void): int
```


## sem_t.wait_function

Return the exact C-only native entry for this operation. Obtain this pointer and retain borrowed owners before starting native work. Foreign calls obey native synchronization/lifetime rules and cannot enter Titan or Lua.

```titan
function sem_t.wait_function(): foreign function(*void): void
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
