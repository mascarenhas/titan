# fs API reference

Complete public example: [fs_watch](../examples/fs_watch.titan). See the
[example guide](../examples/README.md) for build/run commands and platform conditions.

FS callbacks are optional: nil selects synchronous execution; a nonnil callback selects one deferred completion after accepted submission. fs_t is a request, never a handle. Cleanup is explicit after synchronous result, async completion, or immediate native FS rejection. Read string/stat/directory-entry accessors before cleanup; they return copies that survive cleanup. fs_req_cleanup does not close descriptors or directories. A read directory remains busy until its request is cleaned. Successful closedir consumes the directory; cancellation preserves it for retry.

## fs_access

`uv_fs_access` — **canonical exported function**

Check existence or requested access bits for a path; this does not reserve permission for a later operation.

```titan
function fs_access(loop: loop_t?, request: fs_t, path: string, mode: integer, callback: (function (fs_t): ())?): integer
```

**Inputs and outputs:** loop: INPUT initialized owning loop; accepted handles/requests retain it through retirement. Optional nil is meaningful; see contract.; request: INPUT/OUTPUT allocated nonpending request owner; FS submissions also require prior cleanup; accepted submission retains owner until its terminal callback returns; rejection owes no async callback.; path: INPUT immutable text/byte owner; native C-string conventions apply where the operation takes text. FS path strings remain retained until request cleanup; other synchronous borrows end when the call returns.; mode: INPUT integer value; checked native narrowing occurs before native ownership is accepted.; callback: INPUT ordinary callable, retained until the promised callback interval ends; callback argument owners are borrowed views retained through callback return. Optional nil is meaningful; see contract.

**Result, lifetime and cleanup:** Return type: integer. With callback nil, the call completes synchronously and returns its operation result. With a callback, a nonnegative submission accepts one deferred completion; a negative immediate return owes no callback. Read the terminal operation result with fs_get_result. A prepared dirty request requires fs_req_cleanup after synchronous completion, callback completion, or native rejection; a binding preflight rejection creates no new cleanup obligation.

**Callbacks:** optional-sync-or-deferred-once. the owning main Lua thread; timing is specified above

**Cancellation:** FS (accepted async only)

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L1591).


## fs_chmod

`uv_fs_chmod` — **canonical exported function**

Change permission mode bits on the named path.

```titan
function fs_chmod(loop: loop_t?, request: fs_t, path: string, mode: integer, callback: (function (fs_t): ())?): integer
```

**Inputs and outputs:** loop: INPUT initialized owning loop; accepted handles/requests retain it through retirement. Optional nil is meaningful; see contract.; request: INPUT/OUTPUT allocated nonpending request owner; FS submissions also require prior cleanup; accepted submission retains owner until its terminal callback returns; rejection owes no async callback.; path: INPUT immutable text/byte owner; native C-string conventions apply where the operation takes text. FS path strings remain retained until request cleanup; other synchronous borrows end when the call returns.; mode: INPUT integer value; checked native narrowing occurs before native ownership is accepted.; callback: INPUT ordinary callable, retained until the promised callback interval ends; callback argument owners are borrowed views retained through callback return. Optional nil is meaningful; see contract.

**Result, lifetime and cleanup:** Return type: integer. With callback nil, the call completes synchronously and returns its operation result. With a callback, a nonnegative submission accepts one deferred completion; a negative immediate return owes no callback. Read the terminal operation result with fs_get_result. A prepared dirty request requires fs_req_cleanup after synchronous completion, callback completion, or native rejection; a binding preflight rejection creates no new cleanup obligation.

**Callbacks:** optional-sync-or-deferred-once. the owning main Lua thread; timing is specified above

**Cancellation:** FS (accepted async only)

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L1596).


## fs_chown

`uv_fs_chown` — **canonical exported function**

Change owner/group IDs on the named path, following symbolic links.

```titan
function fs_chown(loop: loop_t?, request: fs_t, path: string, uid: integer, gid: integer, callback: (function (fs_t): ())?): integer
```

**Inputs and outputs:** loop: INPUT initialized owning loop; accepted handles/requests retain it through retirement. Optional nil is meaningful; see contract.; request: INPUT/OUTPUT allocated nonpending request owner; FS submissions also require prior cleanup; accepted submission retains owner until its terminal callback returns; rejection owes no async callback.; path: INPUT immutable text/byte owner; native C-string conventions apply where the operation takes text. FS path strings remain retained until request cleanup; other synchronous borrows end when the call returns.; uid: INPUT integer value; checked native narrowing occurs before native ownership is accepted.; gid: INPUT integer value; checked native narrowing occurs before native ownership is accepted.; callback: INPUT ordinary callable, retained until the promised callback interval ends; callback argument owners are borrowed views retained through callback return. Optional nil is meaningful; see contract.

**Result, lifetime and cleanup:** Return type: integer. With callback nil, the call completes synchronously and returns its operation result. With a callback, a nonnegative submission accepts one deferred completion; a negative immediate return owes no callback. Read the terminal operation result with fs_get_result. A prepared dirty request requires fs_req_cleanup after synchronous completion, callback completion, or native rejection; a binding preflight rejection creates no new cleanup obligation.

**Callbacks:** optional-sync-or-deferred-once. the owning main Lua thread; timing is specified above

**Cancellation:** FS (accepted async only)

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L1662).


## fs_close

`uv_fs_close` — **canonical exported function**

Close the supplied integer descriptor. Completion owns the result of the close attempt; request cleanup does not close a descriptor by itself.

```titan
function fs_close(loop: loop_t?, request: fs_t, file: integer, callback: (function (fs_t): ())?): integer
```

**Inputs and outputs:** loop: INPUT initialized owning loop; accepted handles/requests retain it through retirement. Optional nil is meaningful; see contract.; request: INPUT/OUTPUT allocated nonpending request owner; FS submissions also require prior cleanup; accepted submission retains owner until its terminal callback returns; rejection owes no async callback.; file: INPUT integer value; checked native narrowing occurs before native ownership is accepted.; callback: INPUT ordinary callable, retained until the promised callback interval ends; callback argument owners are borrowed views retained through callback return. Optional nil is meaningful; see contract.

**Result, lifetime and cleanup:** Return type: integer. With callback nil, the call completes synchronously and returns its operation result. With a callback, a nonnegative submission accepts one deferred completion; a negative immediate return owes no callback. Read the terminal operation result with fs_get_result. A prepared dirty request requires fs_req_cleanup after synchronous completion, callback completion, or native rejection; a binding preflight rejection creates no new cleanup obligation. This raw integer-descriptor API does not implement high-level File ownership transfer. A successfully cancelled queued request may never execute close, leaving the descriptor open. Request cleanup never closes the descriptor. Interpret other close errors according to the platform; do not blindly retry an ambiguous close.

**Callbacks:** optional-sync-or-deferred-once. the owning main Lua thread; timing is specified above

**Cancellation:** FS (accepted async only)

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L1470).


## fs_closedir

`uv_fs_closedir` — **canonical exported function**

Close an explicitly owned directory returned by fs_opendir. Keep it live through completion; a cancelled request leaves it open for retry.

```titan
function fs_closedir(loop: loop_t?, request: fs_t, directory: dir_t, callback: (function (fs_t): ())?): integer
```

**Inputs and outputs:** loop: INPUT initialized owning loop; accepted handles/requests retain it through retirement. Optional nil is meaningful; see contract.; request: INPUT/OUTPUT allocated nonpending request owner; FS submissions also require prior cleanup; accepted submission retains owner until its terminal callback returns; rejection owes no async callback.; directory: INPUT/OUTPUT open directory owner from fs_opendir; readdir borrows it through fs_req_cleanup, closedir separately disposes it on success.; callback: INPUT ordinary callable, retained until the promised callback interval ends; callback argument owners are borrowed views retained through callback return. Optional nil is meaningful; see contract.

**Result, lifetime and cleanup:** Return type: integer. With callback nil, the call completes synchronously and returns its operation result. With a callback, a nonnegative submission accepts one deferred completion; a negative immediate return owes no callback. Read the terminal operation result with fs_get_result. A prepared dirty request requires fs_req_cleanup after synchronous completion, callback completion, or native rejection; a binding preflight rejection creates no new cleanup obligation. The directory is busy through completion. Success closes the native directory and invalidates its dir_t resource; failure or queued cancellation leaves it open for retry. Clean the request separately. Cleanup does not free a preserved directory.

**Callbacks:** optional-sync-or-deferred-once. the owning main Lua thread; timing is specified above

**Cancellation:** FS (accepted async only)

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L1554).


## fs_copyfile

`uv_fs_copyfile` — **canonical exported function**

Copy a file from path to new_path with native COPYFILE flags; native errors may leave a destination requiring application policy.

```titan
function fs_copyfile(loop: loop_t?, request: fs_t, path: string, new_path: string, flags: integer, callback: (function (fs_t): ())?): integer
```

**Inputs and outputs:** loop: INPUT initialized owning loop; accepted handles/requests retain it through retirement. Optional nil is meaningful; see contract.; request: INPUT/OUTPUT allocated nonpending request owner; FS submissions also require prior cleanup; accepted submission retains owner until its terminal callback returns; rejection owes no async callback.; path: INPUT immutable text/byte owner; native C-string conventions apply where the operation takes text. FS path strings remain retained until request cleanup; other synchronous borrows end when the call returns.; new_path: INPUT immutable text/byte owner; native C-string conventions apply where the operation takes text. FS path strings remain retained until request cleanup; other synchronous borrows end when the call returns.; flags: INPUT integer value; checked native narrowing occurs before native ownership is accepted.; callback: INPUT ordinary callable, retained until the promised callback interval ends; callback argument owners are borrowed views retained through callback return. Optional nil is meaningful; see contract.

**Result, lifetime and cleanup:** Return type: integer. With callback nil, the call completes synchronously and returns its operation result. With a callback, a nonnegative submission accepts one deferred completion; a negative immediate return owes no callback. Read the terminal operation result with fs_get_result. A prepared dirty request requires fs_req_cleanup after synchronous completion, callback completion, or native rejection; a binding preflight rejection creates no new cleanup obligation.

**Callbacks:** optional-sync-or-deferred-once. the owning main Lua thread; timing is specified above

**Cancellation:** FS (accepted async only)

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L1516).


## fs_fchmod

`uv_fs_fchmod` — **canonical exported function**

Change mode bits through an open descriptor.

```titan
function fs_fchmod(loop: loop_t?, request: fs_t, file: integer, mode: integer, callback: (function (fs_t): ())?): integer
```

**Inputs and outputs:** loop: INPUT initialized owning loop; accepted handles/requests retain it through retirement. Optional nil is meaningful; see contract.; request: INPUT/OUTPUT allocated nonpending request owner; FS submissions also require prior cleanup; accepted submission retains owner until its terminal callback returns; rejection owes no async callback.; file: INPUT integer value; checked native narrowing occurs before native ownership is accepted.; mode: INPUT integer value; checked native narrowing occurs before native ownership is accepted.; callback: INPUT ordinary callable, retained until the promised callback interval ends; callback argument owners are borrowed views retained through callback return. Optional nil is meaningful; see contract.

**Result, lifetime and cleanup:** Return type: integer. With callback nil, the call completes synchronously and returns its operation result. With a callback, a nonnegative submission accepts one deferred completion; a negative immediate return owes no callback. Read the terminal operation result with fs_get_result. A prepared dirty request requires fs_req_cleanup after synchronous completion, callback completion, or native rejection; a binding preflight rejection creates no new cleanup obligation.

**Callbacks:** optional-sync-or-deferred-once. the owning main Lua thread; timing is specified above

**Cancellation:** FS (accepted async only)

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L1657).


## fs_fchown

`uv_fs_fchown` — **canonical exported function**

Change owner/group IDs through an open descriptor.

```titan
function fs_fchown(loop: loop_t?, request: fs_t, file: integer, uid: integer, gid: integer, callback: (function (fs_t): ())?): integer
```

**Inputs and outputs:** loop: INPUT initialized owning loop; accepted handles/requests retain it through retirement. Optional nil is meaningful; see contract.; request: INPUT/OUTPUT allocated nonpending request owner; FS submissions also require prior cleanup; accepted submission retains owner until its terminal callback returns; rejection owes no async callback.; file: INPUT integer value; checked native narrowing occurs before native ownership is accepted.; uid: INPUT integer value; checked native narrowing occurs before native ownership is accepted.; gid: INPUT integer value; checked native narrowing occurs before native ownership is accepted.; callback: INPUT ordinary callable, retained until the promised callback interval ends; callback argument owners are borrowed views retained through callback return. Optional nil is meaningful; see contract.

**Result, lifetime and cleanup:** Return type: integer. With callback nil, the call completes synchronously and returns its operation result. With a callback, a nonnegative submission accepts one deferred completion; a negative immediate return owes no callback. Read the terminal operation result with fs_get_result. A prepared dirty request requires fs_req_cleanup after synchronous completion, callback completion, or native rejection; a binding preflight rejection creates no new cleanup obligation.

**Callbacks:** optional-sync-or-deferred-once. the owning main Lua thread; timing is specified above

**Cancellation:** FS (accepted async only)

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L1668).


## fs_fdatasync

`uv_fs_fdatasync` — **canonical exported function**

Flush file data required for retrieval to stable storage according to native filesystem semantics.

```titan
function fs_fdatasync(loop: loop_t?, request: fs_t, file: integer, callback: (function (fs_t): ())?): integer
```

**Inputs and outputs:** loop: INPUT initialized owning loop; accepted handles/requests retain it through retirement. Optional nil is meaningful; see contract.; request: INPUT/OUTPUT allocated nonpending request owner; FS submissions also require prior cleanup; accepted submission retains owner until its terminal callback returns; rejection owes no async callback.; file: INPUT integer value; checked native narrowing occurs before native ownership is accepted.; callback: INPUT ordinary callable, retained until the promised callback interval ends; callback argument owners are borrowed views retained through callback return. Optional nil is meaningful; see contract.

**Result, lifetime and cleanup:** Return type: integer. With callback nil, the call completes synchronously and returns its operation result. With a callback, a nonnegative submission accepts one deferred completion; a negative immediate return owes no callback. Read the terminal operation result with fs_get_result. A prepared dirty request requires fs_req_cleanup after synchronous completion, callback completion, or native rejection; a binding preflight rejection creates no new cleanup obligation.

**Callbacks:** optional-sync-or-deferred-once. the owning main Lua thread; timing is specified above

**Cancellation:** FS (accepted async only)

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L1575).


## fs_fstat

`uv_fs_fstat` — **canonical exported function**

Read metadata through an open descriptor; copy the completed stat value before request cleanup.

```titan
function fs_fstat(loop: loop_t?, request: fs_t, file: integer, callback: (function (fs_t): ())?): integer
```

**Inputs and outputs:** loop: INPUT initialized owning loop; accepted handles/requests retain it through retirement. Optional nil is meaningful; see contract.; request: INPUT/OUTPUT allocated nonpending request owner; FS submissions also require prior cleanup; accepted submission retains owner until its terminal callback returns; rejection owes no async callback.; file: INPUT integer value; checked native narrowing occurs before native ownership is accepted.; callback: INPUT ordinary callable, retained until the promised callback interval ends; callback argument owners are borrowed views retained through callback return. Optional nil is meaningful; see contract.

**Result, lifetime and cleanup:** Return type: integer. With callback nil, the call completes synchronously and returns its operation result. With a callback, a nonnegative submission accepts one deferred completion; a negative immediate return owes no callback. Read the terminal operation result with fs_get_result. A prepared dirty request requires fs_req_cleanup after synchronous completion, callback completion, or native rejection; a binding preflight rejection creates no new cleanup obligation.

**Callbacks:** optional-sync-or-deferred-once. the owning main Lua thread; timing is specified above

**Cancellation:** FS (accepted async only)

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L1562).


## fs_fsync

`uv_fs_fsync` — **canonical exported function**

Flush file data and associated metadata to stable storage according to native filesystem semantics.

```titan
function fs_fsync(loop: loop_t?, request: fs_t, file: integer, callback: (function (fs_t): ())?): integer
```

**Inputs and outputs:** loop: INPUT initialized owning loop; accepted handles/requests retain it through retirement. Optional nil is meaningful; see contract.; request: INPUT/OUTPUT allocated nonpending request owner; FS submissions also require prior cleanup; accepted submission retains owner until its terminal callback returns; rejection owes no async callback.; file: INPUT integer value; checked native narrowing occurs before native ownership is accepted.; callback: INPUT ordinary callable, retained until the promised callback interval ends; callback argument owners are borrowed views retained through callback return. Optional nil is meaningful; see contract.

**Result, lifetime and cleanup:** Return type: integer. With callback nil, the call completes synchronously and returns its operation result. With a callback, a nonnegative submission accepts one deferred completion; a negative immediate return owes no callback. Read the terminal operation result with fs_get_result. A prepared dirty request requires fs_req_cleanup after synchronous completion, callback completion, or native rejection; a binding preflight rejection creates no new cleanup obligation.

**Callbacks:** optional-sync-or-deferred-once. the owning main Lua thread; timing is specified above

**Cancellation:** FS (accepted async only)

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L1571).


## fs_ftruncate

`uv_fs_ftruncate` — **canonical exported function**

Set file length to offset bytes through an open descriptor.

```titan
function fs_ftruncate(loop: loop_t?, request: fs_t, file: integer, offset: integer, callback: (function (fs_t): ())?): integer
```

**Inputs and outputs:** loop: INPUT initialized owning loop; accepted handles/requests retain it through retirement. Optional nil is meaningful; see contract.; request: INPUT/OUTPUT allocated nonpending request owner; FS submissions also require prior cleanup; accepted submission retains owner until its terminal callback returns; rejection owes no async callback.; file: INPUT integer value; checked native narrowing occurs before native ownership is accepted.; offset: INPUT integer value; checked native narrowing occurs before native ownership is accepted.; callback: INPUT ordinary callable, retained until the promised callback interval ends; callback argument owners are borrowed views retained through callback return. Optional nil is meaningful; see contract.

**Result, lifetime and cleanup:** Return type: integer. With callback nil, the call completes synchronously and returns its operation result. With a callback, a nonnegative submission accepts one deferred completion; a negative immediate return owes no callback. Read the terminal operation result with fs_get_result. A prepared dirty request requires fs_req_cleanup after synchronous completion, callback completion, or native rejection; a binding preflight rejection creates no new cleanup obligation.

**Callbacks:** optional-sync-or-deferred-once. the owning main Lua thread; timing is specified above

**Cancellation:** FS (accepted async only)

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L1579).


## fs_futime

`uv_fs_futime` — **canonical exported function**

Set access/modification times through a descriptor; atime and mtime are floating-point seconds.

```titan
function fs_futime(loop: loop_t?, request: fs_t, file: integer, atime: float, mtime: float, callback: (function (fs_t): ())?): integer
```

**Inputs and outputs:** loop: INPUT initialized owning loop; accepted handles/requests retain it through retirement. Optional nil is meaningful; see contract.; request: INPUT/OUTPUT allocated nonpending request owner; FS submissions also require prior cleanup; accepted submission retains owner until its terminal callback returns; rejection owes no async callback.; file: INPUT integer value; checked native narrowing occurs before native ownership is accepted.; atime: INPUT float value; checked native narrowing occurs before native ownership is accepted.; mtime: INPUT float value; checked native narrowing occurs before native ownership is accepted.; callback: INPUT ordinary callable, retained until the promised callback interval ends; callback argument owners are borrowed views retained through callback return. Optional nil is meaningful; see contract.

**Result, lifetime and cleanup:** Return type: integer. With callback nil, the call completes synchronously and returns its operation result. With a callback, a nonnegative submission accepts one deferred completion; a negative immediate return owes no callback. Read the terminal operation result with fs_get_result. A prepared dirty request requires fs_req_cleanup after synchronous completion, callback completion, or native rejection; a binding preflight rejection creates no new cleanup obligation.

**Callbacks:** optional-sync-or-deferred-once. the owning main Lua thread; timing is specified above

**Cancellation:** FS (accepted async only)

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L1609).


## fs_get_path

`uv_fs_get_path` — **canonical exported function**

Copy the path associated with a completed request; the returned string survives request cleanup.

```titan
function fs_get_path(request: fs_t): string?
```

**Inputs and outputs:** request: INPUT existing fs_t owner; this synchronous operation requires nonpending state and enforces the result-kind/cleanup rules below.

**Result, lifetime and cleanup:** Return type: string?. Requires a nonpending request; pending access raises. Returns nil for a clean request or missing native path, otherwise a copied string. Obtain the value before cleanup; a returned string survives cleanup and request reuse.

**Callbacks:** none. no callback

**Cancellation:** not applicable; this operation submits no request

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L1466).


## fs_get_ptr

`uv_fs_get_ptr` — **canonical exported function**

Obtain the typed result view appropriate to the completed request kind; copy or retain its documented result before cleaning the request.

```titan
function fs_get_ptr(request: fs_t): fs_ptr_t?
```

**Inputs and outputs:** request: INPUT existing fs_t owner; this synchronous operation requires nonpending state and enforces the result-kind/cleanup rules below.

**Result, lifetime and cleanup:** Return type: fs_ptr_t?. Requires a nonpending request; pending access raises. Returns a typed fs_ptr_t variant, not a foreign pointer. stat, entries, statfs and path contain copied values that survive cleanup; directory contains the separate dir_t resource; scandir retains the request and can only iterate while its listing remains uncleaned. Returns nil for a clean request, absent native pointer, or unsupported result kind. Typed result accessors still enforce success and operation kind.

**Callbacks:** none. no callback

**Cancellation:** not applicable; this operation submits no request

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L1465).


## fs_get_result

`uv_fs_get_result` — **canonical exported function**

Read the completed operation's signed native result: negative status, zero success, or the documented count/descriptor.

```titan
function fs_get_result(request: fs_t): integer
```

**Inputs and outputs:** request: INPUT existing fs_t owner; this synchronous operation requires nonpending state and enforces the result-kind/cleanup rules below.

**Result, lifetime and cleanup:** Return type: integer. Requires a nonpending request; pending access raises. Returns the stored operation result: a negative libuv error, or the operation-specific success value such as descriptor, byte count, or zero. This synchronous query neither cleans the request nor transfers any resource.

**Callbacks:** none. no callback

**Cancellation:** not applicable; this operation submits no request

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L1463).


## fs_get_statbuf

`uv_fs_get_statbuf` — **canonical exported function**

Copy the completed stat buffer into a public stat_t value that survives cleanup.

```titan
function fs_get_statbuf(request: fs_t): stat_t
```

**Inputs and outputs:** request: INPUT existing fs_t owner; this synchronous operation requires nonpending state and enforces the result-kind/cleanup rules below.

**Result, lifetime and cleanup:** Return type: stat_t. Requires a completed dirty successful stat/fstat/lstat request; other states raise. Returns an independent stat_t, including copied timespec records, which survives request cleanup and reuse.

**Callbacks:** none. no callback

**Cancellation:** not applicable; this operation submits no request

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L1467).


## fs_get_system_error

`uv_fs_get_system_error` — **canonical exported function**

Read the completed request's original platform system-error value. This is distinct from its libuv result status.

```titan
function fs_get_system_error(request: fs_t): integer
```

**Inputs and outputs:** request: INPUT existing fs_t owner; this synchronous operation requires nonpending state and enforces the result-kind/cleanup rules below.

**Result, lifetime and cleanup:** Return type: integer. Requires a nonpending request; pending access raises. Returns the native system error for the completed operation. This is a platform error domain, distinct from the libuv status in fs_get_result. No cleanup is performed.

**Callbacks:** none. no callback

**Cancellation:** not applicable; this operation submits no request

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L1464).


## fs_get_type

`uv_fs_get_type` — **canonical exported function**

Read the request's filesystem operation kind as fs_type_t.

```titan
function fs_get_type(request: fs_t): fs_type_t
```

**Inputs and outputs:** request: INPUT existing fs_t owner; this synchronous operation requires nonpending state and enforces the result-kind/cleanup rules below.

**Result, lifetime and cleanup:** Return type: fs_type_t. Requires a nonpending fs_t; pending access raises. Returns the stored FS operation kind as fs_type_t, including unknown before any operation. It neither submits work nor cleans a dirty result; normal result cleanup obligations remain unchanged.

**Callbacks:** none. no callback

**Cancellation:** not applicable; this operation submits no request

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L1462).


## fs_lchown

`uv_fs_lchown` — **canonical exported function**

Change owner/group IDs on the symbolic link itself rather than its target.

```titan
function fs_lchown(loop: loop_t?, request: fs_t, path: string, uid: integer, gid: integer, callback: (function (fs_t): ())?): integer
```

**Inputs and outputs:** loop: INPUT initialized owning loop; accepted handles/requests retain it through retirement. Optional nil is meaningful; see contract.; request: INPUT/OUTPUT allocated nonpending request owner; FS submissions also require prior cleanup; accepted submission retains owner until its terminal callback returns; rejection owes no async callback.; path: INPUT immutable text/byte owner; native C-string conventions apply where the operation takes text. FS path strings remain retained until request cleanup; other synchronous borrows end when the call returns.; uid: INPUT integer value; checked native narrowing occurs before native ownership is accepted.; gid: INPUT integer value; checked native narrowing occurs before native ownership is accepted.; callback: INPUT ordinary callable, retained until the promised callback interval ends; callback argument owners are borrowed views retained through callback return. Optional nil is meaningful; see contract.

**Result, lifetime and cleanup:** Return type: integer. With callback nil, the call completes synchronously and returns its operation result. With a callback, a nonnegative submission accepts one deferred completion; a negative immediate return owes no callback. Read the terminal operation result with fs_get_result. A prepared dirty request requires fs_req_cleanup after synchronous completion, callback completion, or native rejection; a binding preflight rejection creates no new cleanup obligation.

**Callbacks:** optional-sync-or-deferred-once. the owning main Lua thread; timing is specified above

**Cancellation:** FS (accepted async only)

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L1674).


## fs_link

`uv_fs_link` — **canonical exported function**

Create new_path as a hard link to path.

```titan
function fs_link(loop: loop_t?, request: fs_t, path: string, new_path: string, callback: (function (fs_t): ())?): integer
```

**Inputs and outputs:** loop: INPUT initialized owning loop; accepted handles/requests retain it through retirement. Optional nil is meaningful; see contract.; request: INPUT/OUTPUT allocated nonpending request owner; FS submissions also require prior cleanup; accepted submission retains owner until its terminal callback returns; rejection owes no async callback.; path: INPUT immutable text/byte owner; native C-string conventions apply where the operation takes text. FS path strings remain retained until request cleanup; other synchronous borrows end when the call returns.; new_path: INPUT immutable text/byte owner; native C-string conventions apply where the operation takes text. FS path strings remain retained until request cleanup; other synchronous borrows end when the call returns.; callback: INPUT ordinary callable, retained until the promised callback interval ends; callback argument owners are borrowed views retained through callback return. Optional nil is meaningful; see contract.

**Result, lifetime and cleanup:** Return type: integer. With callback nil, the call completes synchronously and returns its operation result. With a callback, a nonnegative submission accepts one deferred completion; a negative immediate return owes no callback. Read the terminal operation result with fs_get_result. A prepared dirty request requires fs_req_cleanup after synchronous completion, callback completion, or native rejection; a binding preflight rejection creates no new cleanup obligation.

**Callbacks:** optional-sync-or-deferred-once. the owning main Lua thread; timing is specified above

**Cancellation:** FS (accepted async only)

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L1625).


## fs_lstat

`uv_fs_lstat` — **canonical exported function**

Read path metadata without following the final symbolic link.

```titan
function fs_lstat(loop: loop_t?, request: fs_t, path: string, callback: (function (fs_t): ())?): integer
```

**Inputs and outputs:** loop: INPUT initialized owning loop; accepted handles/requests retain it through retirement. Optional nil is meaningful; see contract.; request: INPUT/OUTPUT allocated nonpending request owner; FS submissions also require prior cleanup; accepted submission retains owner until its terminal callback returns; rejection owes no async callback.; path: INPUT immutable text/byte owner; native C-string conventions apply where the operation takes text. FS path strings remain retained until request cleanup; other synchronous borrows end when the call returns.; callback: INPUT ordinary callable, retained until the promised callback interval ends; callback argument owners are borrowed views retained through callback return. Optional nil is meaningful; see contract.

**Result, lifetime and cleanup:** Return type: integer. With callback nil, the call completes synchronously and returns its operation result. With a callback, a nonnegative submission accepts one deferred completion; a negative immediate return owes no callback. Read the terminal operation result with fs_get_result. A prepared dirty request requires fs_req_cleanup after synchronous completion, callback completion, or native rejection; a binding preflight rejection creates no new cleanup obligation.

**Callbacks:** optional-sync-or-deferred-once. the owning main Lua thread; timing is specified above

**Cancellation:** FS (accepted async only)

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L1621).


## fs_lutime

`uv_fs_lutime` — **canonical exported function**

Change a symbolic link's access/modification times without following it; times are floating-point seconds.

```titan
function fs_lutime(loop: loop_t?, request: fs_t, path: string, atime: float, mtime: float, callback: (function (fs_t): ())?): integer
```

**Inputs and outputs:** loop: INPUT initialized owning loop; accepted handles/requests retain it through retirement. Optional nil is meaningful; see contract.; request: INPUT/OUTPUT allocated nonpending request owner; FS submissions also require prior cleanup; accepted submission retains owner until its terminal callback returns; rejection owes no async callback.; path: INPUT immutable text/byte owner; native C-string conventions apply where the operation takes text. FS path strings remain retained until request cleanup; other synchronous borrows end when the call returns.; atime: INPUT float value; checked native narrowing occurs before native ownership is accepted.; mtime: INPUT float value; checked native narrowing occurs before native ownership is accepted.; callback: INPUT ordinary callable, retained until the promised callback interval ends; callback argument owners are borrowed views retained through callback return. Optional nil is meaningful; see contract.

**Result, lifetime and cleanup:** Return type: integer. With callback nil, the call completes synchronously and returns its operation result. With a callback, a nonnegative submission accepts one deferred completion; a negative immediate return owes no callback. Read the terminal operation result with fs_get_result. A prepared dirty request requires fs_req_cleanup after synchronous completion, callback completion, or native rejection; a binding preflight rejection creates no new cleanup obligation.

**Callbacks:** optional-sync-or-deferred-once. the owning main Lua thread; timing is specified above

**Cancellation:** FS (accepted async only)

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L1615).


## fs_mkdir

`uv_fs_mkdir` — **canonical exported function**

Create a directory using the requested mode bits.

```titan
function fs_mkdir(loop: loop_t?, request: fs_t, path: string, mode: integer, callback: (function (fs_t): ())?): integer
```

**Inputs and outputs:** loop: INPUT initialized owning loop; accepted handles/requests retain it through retirement. Optional nil is meaningful; see contract.; request: INPUT/OUTPUT allocated nonpending request owner; FS submissions also require prior cleanup; accepted submission retains owner until its terminal callback returns; rejection owes no async callback.; path: INPUT immutable text/byte owner; native C-string conventions apply where the operation takes text. FS path strings remain retained until request cleanup; other synchronous borrows end when the call returns.; mode: INPUT integer value; checked native narrowing occurs before native ownership is accepted.; callback: INPUT ordinary callable, retained until the promised callback interval ends; callback argument owners are borrowed views retained through callback return. Optional nil is meaningful; see contract.

**Result, lifetime and cleanup:** Return type: integer. With callback nil, the call completes synchronously and returns its operation result. With a callback, a nonnegative submission accepts one deferred completion; a negative immediate return owes no callback. Read the terminal operation result with fs_get_result. A prepared dirty request requires fs_req_cleanup after synchronous completion, callback completion, or native rejection; a binding preflight rejection creates no new cleanup obligation.

**Callbacks:** optional-sync-or-deferred-once. the owning main Lua thread; timing is specified above

**Cancellation:** FS (accepted async only)

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L1522).


## fs_mkdtemp

`uv_fs_mkdtemp` — **canonical exported function**

Replace the trailing XXXXXX template with a unique directory name. Copy the completed path before request cleanup; the directory remains caller-owned.

```titan
function fs_mkdtemp(loop: loop_t?, request: fs_t, path: string, callback: (function (fs_t): ())?): integer
```

**Inputs and outputs:** loop: INPUT initialized owning loop; accepted handles/requests retain it through retirement. Optional nil is meaningful; see contract.; request: INPUT/OUTPUT allocated nonpending request owner; FS submissions also require prior cleanup; accepted submission retains owner until its terminal callback returns; rejection owes no async callback.; path: INPUT immutable text/byte owner; native C-string conventions apply where the operation takes text. FS path strings remain retained until request cleanup; other synchronous borrows end when the call returns.; callback: INPUT ordinary callable, retained until the promised callback interval ends; callback argument owners are borrowed views retained through callback return. Optional nil is meaningful; see contract.

**Result, lifetime and cleanup:** Return type: integer. With callback nil, the call completes synchronously and returns its operation result. With a callback, a nonnegative submission accepts one deferred completion; a negative immediate return owes no callback. Read the terminal operation result with fs_get_result. A prepared dirty request requires fs_req_cleanup after synchronous completion, callback completion, or native rejection; a binding preflight rejection creates no new cleanup obligation. After success, fs_get_path copies the created directory name. Read it before request cleanup; the copied string survives. The directory persists until an explicit rmdir.

**Callbacks:** optional-sync-or-deferred-once. the owning main Lua thread; timing is specified above

**Cancellation:** FS (accepted async only)

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L1527).


## fs_mkstemp

`uv_fs_mkstemp` — **canonical exported function**

Create a unique file from the trailing XXXXXX template. The completed result is an owning descriptor and the request exposes the generated path; cleanup releases neither file ownership nor its pathname on disk.

```titan
function fs_mkstemp(loop: loop_t?, request: fs_t, path: string, callback: (function (fs_t): ())?): integer
```

**Inputs and outputs:** loop: INPUT initialized owning loop; accepted handles/requests retain it through retirement. Optional nil is meaningful; see contract.; request: INPUT/OUTPUT allocated nonpending request owner; FS submissions also require prior cleanup; accepted submission retains owner until its terminal callback returns; rejection owes no async callback.; path: INPUT immutable text/byte owner; native C-string conventions apply where the operation takes text. FS path strings remain retained until request cleanup; other synchronous borrows end when the call returns.; callback: INPUT ordinary callable, retained until the promised callback interval ends; callback argument owners are borrowed views retained through callback return. Optional nil is meaningful; see contract.

**Result, lifetime and cleanup:** Return type: integer. With callback nil, the call completes synchronously and returns its operation result. With a callback, a nonnegative submission accepts one deferred completion; a negative immediate return owes no callback. Read the terminal operation result with fs_get_result. A prepared dirty request requires fs_req_cleanup after synchronous completion, callback completion, or native rejection; a binding preflight rejection creates no new cleanup obligation. Success returns a separately owned descriptor and a generated path. fs_get_path copies the path before request cleanup. Cleanup does not close the descriptor.

**Callbacks:** optional-sync-or-deferred-once. the owning main Lua thread; timing is specified above

**Cancellation:** FS (accepted async only)

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L1531).


## fs_open

`uv_fs_open` — **canonical exported function**

Open path with native O_* flags and creation mode. A successful completed result is an owning descriptor that the caller must eventually close.

```titan
function fs_open(loop: loop_t?, request: fs_t, path: string, flags: integer, mode: integer, callback: (function (fs_t): ())?): integer
```

**Inputs and outputs:** loop: INPUT initialized owning loop; accepted handles/requests retain it through retirement. Optional nil is meaningful; see contract.; request: INPUT/OUTPUT allocated nonpending request owner; FS submissions also require prior cleanup; accepted submission retains owner until its terminal callback returns; rejection owes no async callback.; path: INPUT immutable text/byte owner; native C-string conventions apply where the operation takes text. FS path strings remain retained until request cleanup; other synchronous borrows end when the call returns.; flags: INPUT integer value; checked native narrowing occurs before native ownership is accepted.; mode: INPUT integer value; checked native narrowing occurs before native ownership is accepted.; callback: INPUT ordinary callable, retained until the promised callback interval ends; callback argument owners are borrowed views retained through callback return. Optional nil is meaningful; see contract.

**Result, lifetime and cleanup:** Return type: integer. With callback nil, the call completes synchronously and returns its operation result. With a callback, a nonnegative submission accepts one deferred completion; a negative immediate return owes no callback. Read the terminal operation result with fs_get_result. A prepared dirty request requires fs_req_cleanup after synchronous completion, callback completion, or native rejection; a binding preflight rejection creates no new cleanup obligation. Successful result is caller-owned file descriptor, not request memory; cleanup does not close it.

**Callbacks:** optional-sync-or-deferred-once. the owning main Lua thread; timing is specified above

**Cancellation:** FS (accepted async only)

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L1474).


## fs_opendir

`uv_fs_opendir` — **canonical exported function**

Open a directory and return it through the completed request's typed directory result. Directory ownership continues past request cleanup until fs_closedir.

```titan
function fs_opendir(loop: loop_t?, request: fs_t, path: string, callback: (function (fs_t): ())?): integer
```

**Inputs and outputs:** loop: INPUT initialized owning loop; accepted handles/requests retain it through retirement. Optional nil is meaningful; see contract.; request: INPUT/OUTPUT allocated nonpending request owner; FS submissions also require prior cleanup; accepted submission retains owner until its terminal callback returns; rejection owes no async callback.; path: INPUT immutable text/byte owner; native C-string conventions apply where the operation takes text. FS path strings remain retained until request cleanup; other synchronous borrows end when the call returns.; callback: INPUT ordinary callable, retained until the promised callback interval ends; callback argument owners are borrowed views retained through callback return. Optional nil is meaningful; see contract.

**Result, lifetime and cleanup:** Return type: integer. With callback nil, the call completes synchronously and returns its operation result. With a callback, a nonnegative submission accepts one deferred completion; a negative immediate return owes no callback. Read the terminal operation result with fs_get_result. A prepared dirty request requires fs_req_cleanup after synchronous completion, callback completion, or native rejection; a binding preflight rejection creates no new cleanup obligation. Success creates a separately owned directory. Obtain its dir_t with fs_get_dir before cleaning this request; fs_req_cleanup does not close it. Release it later with fs_closedir.

**Callbacks:** optional-sync-or-deferred-once. the owning main Lua thread; timing is specified above

**Cancellation:** FS (accepted async only)

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L1546).


## fs_read

`uv_fs_read` — **canonical exported function**

Read into writable buffer vectors. Offset -1 uses/updates the descriptor position; otherwise offset is an explicit byte position. Completion returns bytes read, with zero meaning EOF.

```titan
function fs_read(loop: loop_t?, request: fs_t, file: integer, buffers: {buf_t}, offset: integer, callback: (function (fs_t): ())?): integer
```

**Inputs and outputs:** loop: INPUT initialized owning loop; accepted handles/requests retain it through retirement. Optional nil is meaningful; see contract.; request: INPUT/OUTPUT allocated nonpending request owner; FS submissions also require prior cleanup; accepted submission retains owner until its terminal callback returns; rejection owes no async callback.; file: INPUT integer value; checked native narrowing occurs before native ownership is accepted.; buffers: OUTPUT writable owned byte storage; caller allocates capacity, native operation writes bytes; accepted async borrow retained through terminal callback/cleanup.; offset: INPUT integer value; checked native narrowing occurs before native ownership is accepted.; callback: INPUT ordinary callable, retained until the promised callback interval ends; callback argument owners are borrowed views retained through callback return. Optional nil is meaningful; see contract.

**Result, lifetime and cleanup:** Return type: integer. With callback nil, the call completes synchronously and returns its operation result. With a callback, a nonnegative submission accepts one deferred completion; a negative immediate return owes no callback. Read the terminal operation result with fs_get_result. A prepared dirty request requires fs_req_cleanup after synchronous completion, callback completion, or native rejection; a binding preflight rejection creates no new cleanup obligation. bufs metadata input, byte buffers writable output; offset -1 updates file offset; positive result is bytes, zero EOF.

**Callbacks:** optional-sync-or-deferred-once. the owning main Lua thread; timing is specified above

**Cancellation:** FS (accepted async only)

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L1480).


## fs_readdir

`uv_fs_readdir` — **canonical exported function**

Read up to capacity entries from an open directory. Copy returned entries before request cleanup; zero entries means directory exhaustion.

```titan
function fs_readdir(loop: loop_t?, request: fs_t, directory: dir_t, capacity: integer, callback: (function (fs_t): ())?): integer
```

**Inputs and outputs:** loop: INPUT initialized owning loop; accepted handles/requests retain it through retirement. Optional nil is meaningful; see contract.; request: INPUT/OUTPUT allocated nonpending request owner; FS submissions also require prior cleanup; accepted submission retains owner until its terminal callback returns; rejection owes no async callback.; directory: INPUT/OUTPUT open directory owner from fs_opendir; readdir borrows it through fs_req_cleanup, closedir separately disposes it on success.; capacity: INPUT integer value; checked native narrowing occurs before native ownership is accepted.; callback: INPUT ordinary callable, retained until the promised callback interval ends; callback argument owners are borrowed views retained through callback return. Optional nil is meaningful; see contract.

**Result, lifetime and cleanup:** Return type: integer. With callback nil, the call completes synchronously and returns its operation result. With a callback, a nonnegative submission accepts one deferred completion; a negative immediate return owes no callback. Read the terminal operation result with fs_get_result. A prepared dirty request requires fs_req_cleanup after synchronous completion, callback completion, or native rejection; a binding preflight rejection creates no new cleanup obligation. The binding allocates the native entry array from capacity and retains it with the request. The directory remains busy until fs_req_cleanup, including after immediate native rejection or queued cancellation. fs_get_entries returns independent records and copied names. Cleanup releases native entry storage and permits another read or close.

**Callbacks:** optional-sync-or-deferred-once. the owning main Lua thread; timing is specified above

**Cancellation:** FS (accepted async only)

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L1550).


## fs_readlink

`uv_fs_readlink` — **canonical exported function**

Read the contents of a symbolic link. Copy the completed text result before request cleanup.

```titan
function fs_readlink(loop: loop_t?, request: fs_t, path: string, callback: (function (fs_t): ())?): integer
```

**Inputs and outputs:** loop: INPUT initialized owning loop; accepted handles/requests retain it through retirement. Optional nil is meaningful; see contract.; request: INPUT/OUTPUT allocated nonpending request owner; FS submissions also require prior cleanup; accepted submission retains owner until its terminal callback returns; rejection owes no async callback.; path: INPUT immutable text/byte owner; native C-string conventions apply where the operation takes text. FS path strings remain retained until request cleanup; other synchronous borrows end when the call returns.; callback: INPUT ordinary callable, retained until the promised callback interval ends; callback argument owners are borrowed views retained through callback return. Optional nil is meaningful; see contract.

**Result, lifetime and cleanup:** Return type: integer. With callback nil, the call completes synchronously and returns its operation result. With a callback, a nonnegative submission accepts one deferred completion; a negative immediate return owes no callback. Read the terminal operation result with fs_get_result. A prepared dirty request requires fs_req_cleanup after synchronous completion, callback completion, or native rejection; a binding preflight rejection creates no new cleanup obligation. After success, fs_get_string or the path variant of fs_get_ptr copies the link target into an ordinary string. Obtain that copy before request cleanup; retaining the copy afterward is valid.

**Callbacks:** optional-sync-or-deferred-once. the owning main Lua thread; timing is specified above

**Cancellation:** FS (accepted async only)

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L1649).


## fs_realpath

`uv_fs_realpath` — **canonical exported function**

Resolve a path to its native canonical absolute spelling. Copy the completed text result before request cleanup.

```titan
function fs_realpath(loop: loop_t?, request: fs_t, path: string, callback: (function (fs_t): ())?): integer
```

**Inputs and outputs:** loop: INPUT initialized owning loop; accepted handles/requests retain it through retirement. Optional nil is meaningful; see contract.; request: INPUT/OUTPUT allocated nonpending request owner; FS submissions also require prior cleanup; accepted submission retains owner until its terminal callback returns; rejection owes no async callback.; path: INPUT immutable text/byte owner; native C-string conventions apply where the operation takes text. FS path strings remain retained until request cleanup; other synchronous borrows end when the call returns.; callback: INPUT ordinary callable, retained until the promised callback interval ends; callback argument owners are borrowed views retained through callback return. Optional nil is meaningful; see contract.

**Result, lifetime and cleanup:** Return type: integer. With callback nil, the call completes synchronously and returns its operation result. With a callback, a nonnegative submission accepts one deferred completion; a negative immediate return owes no callback. Read the terminal operation result with fs_get_result. A prepared dirty request requires fs_req_cleanup after synchronous completion, callback completion, or native rejection; a binding preflight rejection creates no new cleanup obligation. After success, fs_get_string or the path variant of fs_get_ptr copies the resolved path into an ordinary string. Obtain that copy before request cleanup; retaining the copy afterward is valid.

**Callbacks:** optional-sync-or-deferred-once. the owning main Lua thread; timing is specified above

**Cancellation:** FS (accepted async only)

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L1653).


## fs_rename

`uv_fs_rename` — **canonical exported function**

Rename or move path to new_path using native filesystem semantics.

```titan
function fs_rename(loop: loop_t?, request: fs_t, path: string, new_path: string, callback: (function (fs_t): ())?): integer
```

**Inputs and outputs:** loop: INPUT initialized owning loop; accepted handles/requests retain it through retirement. Optional nil is meaningful; see contract.; request: INPUT/OUTPUT allocated nonpending request owner; FS submissions also require prior cleanup; accepted submission retains owner until its terminal callback returns; rejection owes no async callback.; path: INPUT immutable text/byte owner; native C-string conventions apply where the operation takes text. FS path strings remain retained until request cleanup; other synchronous borrows end when the call returns.; new_path: INPUT immutable text/byte owner; native C-string conventions apply where the operation takes text. FS path strings remain retained until request cleanup; other synchronous borrows end when the call returns.; callback: INPUT ordinary callable, retained until the promised callback interval ends; callback argument owners are borrowed views retained through callback return. Optional nil is meaningful; see contract.

**Result, lifetime and cleanup:** Return type: integer. With callback nil, the call completes synchronously and returns its operation result. With a callback, a nonnegative submission accepts one deferred completion; a negative immediate return owes no callback. Read the terminal operation result with fs_get_result. A prepared dirty request requires fs_req_cleanup after synchronous completion, callback completion, or native rejection; a binding preflight rejection creates no new cleanup obligation.

**Callbacks:** optional-sync-or-deferred-once. the owning main Lua thread; timing is specified above

**Cancellation:** FS (accepted async only)

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L1566).


## fs_req_cleanup

`uv_fs_req_cleanup` — **canonical exported function**

Release memory associated with a terminal or synchronously rejected filesystem request. Do not call while pending; this does not dispose of separately acquired descriptors/directories.

```titan
function fs_req_cleanup(request: fs_t)
```

**Inputs and outputs:** request: INPUT existing fs_t owner; this synchronous operation requires nonpending state and enforces the result-kind/cleanup rules below.

**Result, lifetime and cleanup:** Return type: (). Requires a nonpending request; pending cleanup raises. A clean request is a no-op. Releases request-owned native result storage and retained inputs, and clears a readdir directory busy reservation. This is required before request reuse. It never closes file descriptors or an opendir directory, and never frees a directory preserved after cancelled closedir. Previously copied strings, stat records and entries remain valid.

**Callbacks:** none. no callback

**Cancellation:** not applicable; this operation submits no request

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L1469).


## fs_rmdir

`uv_fs_rmdir` — **canonical exported function**

Remove an empty directory at path.

```titan
function fs_rmdir(loop: loop_t?, request: fs_t, path: string, callback: (function (fs_t): ())?): integer
```

**Inputs and outputs:** loop: INPUT initialized owning loop; accepted handles/requests retain it through retirement. Optional nil is meaningful; see contract.; request: INPUT/OUTPUT allocated nonpending request owner; FS submissions also require prior cleanup; accepted submission retains owner until its terminal callback returns; rejection owes no async callback.; path: INPUT immutable text/byte owner; native C-string conventions apply where the operation takes text. FS path strings remain retained until request cleanup; other synchronous borrows end when the call returns.; callback: INPUT ordinary callable, retained until the promised callback interval ends; callback argument owners are borrowed views retained through callback return. Optional nil is meaningful; see contract.

**Result, lifetime and cleanup:** Return type: integer. With callback nil, the call completes synchronously and returns its operation result. With a callback, a nonnegative submission accepts one deferred completion; a negative immediate return owes no callback. Read the terminal operation result with fs_get_result. A prepared dirty request requires fs_req_cleanup after synchronous completion, callback completion, or native rejection; a binding preflight rejection creates no new cleanup obligation.

**Callbacks:** optional-sync-or-deferred-once. the owning main Lua thread; timing is specified above

**Cancellation:** FS (accepted async only)

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L1535).


## fs_scandir

`uv_fs_scandir` — **canonical exported function**

Collect directory entries for repeated fs_scandir_next calls. Keep the request dirty until enumeration is finished, then clean it.

```titan
function fs_scandir(loop: loop_t?, request: fs_t, path: string, flags: integer, callback: (function (fs_t): ())?): integer
```

**Inputs and outputs:** loop: INPUT initialized owning loop; accepted handles/requests retain it through retirement. Optional nil is meaningful; see contract.; request: INPUT/OUTPUT allocated nonpending request owner; FS submissions also require prior cleanup; accepted submission retains owner until its terminal callback returns; rejection owes no async callback.; path: INPUT immutable text/byte owner; native C-string conventions apply where the operation takes text. FS path strings remain retained until request cleanup; other synchronous borrows end when the call returns.; flags: INPUT integer value; checked native narrowing occurs before native ownership is accepted.; callback: INPUT ordinary callable, retained until the promised callback interval ends; callback argument owners are borrowed views retained through callback return. Optional nil is meaningful; see contract.

**Result, lifetime and cleanup:** Return type: integer. With callback nil, the call completes synchronously and returns its operation result. With a callback, a nonnegative submission accepts one deferred completion; a negative immediate return owes no callback. Read the terminal operation result with fs_get_result. A prepared dirty request requires fs_req_cleanup after synchronous completion, callback completion, or native rejection; a binding preflight rejection creates no new cleanup obligation. The request retains the native listing until fs_req_cleanup. fs_scandir_next copies one entry and name at a time; each returned value survives cleanup. The iterator itself needs the uncleaned request.

**Callbacks:** optional-sync-or-deferred-once. the owning main Lua thread; timing is specified above

**Cancellation:** FS (accepted async only)

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L1539).


## fs_scandir_next

`uv_fs_scandir_next` — **canonical exported function**

Return `(status, entry?)` from a completed scandir request. EOF is the native end-of-enumeration status; copied entries survive later request cleanup.

```titan
function fs_scandir_next(request: fs_t): (integer, dirent_t?)
```

**Inputs and outputs:** request: INPUT existing fs_t owner; this synchronous operation requires nonpending state and enforces the result-kind/cleanup rules below.

**Result, lifetime and cleanup:** Return type: (integer, dirent_t?). Requires a completed dirty scandir request. Returns 0 plus a new dirent_t with a copied name on success, or a negative status and nil, including EOF at the end. Each returned entry survives request cleanup and reuse; further iteration requires the original uncleaned listing.

**Callbacks:** none. no callback

**Cancellation:** not applicable; this operation submits no request

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L1544).


## fs_sendfile

`uv_fs_sendfile` — **canonical exported function**

Copy up to length bytes from in_fd at in_offset to out_fd. Completion reports bytes transferred; both descriptors remain caller-owned.

```titan
function fs_sendfile(loop: loop_t?, request: fs_t, out_fd: integer, in_fd: integer, in_offset: integer, length: integer, callback: (function (fs_t): ())?): integer
```

**Inputs and outputs:** loop: INPUT initialized owning loop; accepted handles/requests retain it through retirement. Optional nil is meaningful; see contract.; request: INPUT/OUTPUT allocated nonpending request owner; FS submissions also require prior cleanup; accepted submission retains owner until its terminal callback returns; rejection owes no async callback.; out_fd: INPUT integer value; checked native narrowing occurs before native ownership is accepted.; in_fd: INPUT integer value; checked native narrowing occurs before native ownership is accepted.; in_offset: INPUT integer value; checked native narrowing occurs before native ownership is accepted.; length: INPUT integer value; checked native narrowing occurs before native ownership is accepted.; callback: INPUT ordinary callable, retained until the promised callback interval ends; callback argument owners are borrowed views retained through callback return. Optional nil is meaningful; see contract.

**Result, lifetime and cleanup:** Return type: integer. With callback nil, the call completes synchronously and returns its operation result. With a callback, a nonnegative submission accepts one deferred completion; a negative immediate return owes no callback. Read the terminal operation result with fs_get_result. A prepared dirty request requires fs_req_cleanup after synchronous completion, callback completion, or native rejection; a binding preflight rejection creates no new cleanup obligation.

**Callbacks:** optional-sync-or-deferred-once. the owning main Lua thread; timing is specified above

**Cancellation:** FS (accepted async only)

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L1584).


## fs_stat

`uv_fs_stat` — **canonical exported function**

Read metadata following the final symbolic link; copy the completed stat value before cleanup.

```titan
function fs_stat(loop: loop_t?, request: fs_t, path: string, callback: (function (fs_t): ())?): integer
```

**Inputs and outputs:** loop: INPUT initialized owning loop; accepted handles/requests retain it through retirement. Optional nil is meaningful; see contract.; request: INPUT/OUTPUT allocated nonpending request owner; FS submissions also require prior cleanup; accepted submission retains owner until its terminal callback returns; rejection owes no async callback.; path: INPUT immutable text/byte owner; native C-string conventions apply where the operation takes text. FS path strings remain retained until request cleanup; other synchronous borrows end when the call returns.; callback: INPUT ordinary callable, retained until the promised callback interval ends; callback argument owners are borrowed views retained through callback return. Optional nil is meaningful; see contract.

**Result, lifetime and cleanup:** Return type: integer. With callback nil, the call completes synchronously and returns its operation result. With a callback, a nonnegative submission accepts one deferred completion; a negative immediate return owes no callback. Read the terminal operation result with fs_get_result. A prepared dirty request requires fs_req_cleanup after synchronous completion, callback completion, or native rejection; a binding preflight rejection creates no new cleanup obligation.

**Callbacks:** optional-sync-or-deferred-once. the owning main Lua thread; timing is specified above

**Cancellation:** FS (accepted async only)

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L1558).


## fs_statfs

`uv_fs_statfs` — **canonical exported function**

Read filesystem statistics for the path and copy the completed typed result before cleanup.

```titan
function fs_statfs(loop: loop_t?, request: fs_t, path: string, callback: (function (fs_t): ())?): integer
```

**Inputs and outputs:** loop: INPUT initialized owning loop; accepted handles/requests retain it through retirement. Optional nil is meaningful; see contract.; request: INPUT/OUTPUT allocated nonpending request owner; FS submissions also require prior cleanup; accepted submission retains owner until its terminal callback returns; rejection owes no async callback.; path: INPUT immutable text/byte owner; native C-string conventions apply where the operation takes text. FS path strings remain retained until request cleanup; other synchronous borrows end when the call returns.; callback: INPUT ordinary callable, retained until the promised callback interval ends; callback argument owners are borrowed views retained through callback return. Optional nil is meaningful; see contract.

**Result, lifetime and cleanup:** Return type: integer. With callback nil, the call completes synchronously and returns its operation result. With a callback, a nonnegative submission accepts one deferred completion; a negative immediate return owes no callback. Read the terminal operation result with fs_get_result. A prepared dirty request requires fs_req_cleanup after synchronous completion, callback completion, or native rejection; a binding preflight rejection creates no new cleanup obligation. After success, fs_get_statfs copies the filesystem statistics, including f_spare, into an independent statfs_t. That value survives request cleanup.

**Callbacks:** optional-sync-or-deferred-once. the owning main Lua thread; timing is specified above

**Cancellation:** FS (accepted async only)

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L1680).


## fs_symlink

`uv_fs_symlink` — **canonical exported function**

Create new_path as a symbolic link to path, with native flags for platform-specific link kinds.

```titan
function fs_symlink(loop: loop_t?, request: fs_t, path: string, new_path: string, flags: integer, callback: (function (fs_t): ())?): integer
```

**Inputs and outputs:** loop: INPUT initialized owning loop; accepted handles/requests retain it through retirement. Optional nil is meaningful; see contract.; request: INPUT/OUTPUT allocated nonpending request owner; FS submissions also require prior cleanup; accepted submission retains owner until its terminal callback returns; rejection owes no async callback.; path: INPUT immutable text/byte owner; native C-string conventions apply where the operation takes text. FS path strings remain retained until request cleanup; other synchronous borrows end when the call returns.; new_path: INPUT immutable text/byte owner; native C-string conventions apply where the operation takes text. FS path strings remain retained until request cleanup; other synchronous borrows end when the call returns.; flags: INPUT integer value; checked native narrowing occurs before native ownership is accepted.; callback: INPUT ordinary callable, retained until the promised callback interval ends; callback argument owners are borrowed views retained through callback return. Optional nil is meaningful; see contract.

**Result, lifetime and cleanup:** Return type: integer. With callback nil, the call completes synchronously and returns its operation result. With a callback, a nonnegative submission accepts one deferred completion; a negative immediate return owes no callback. Read the terminal operation result with fs_get_result. A prepared dirty request requires fs_req_cleanup after synchronous completion, callback completion, or native rejection; a binding preflight rejection creates no new cleanup obligation.

**Callbacks:** optional-sync-or-deferred-once. the owning main Lua thread; timing is specified above

**Cancellation:** FS (accepted async only)

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L1643).


## fs_unlink

`uv_fs_unlink` — **canonical exported function**

Remove a filesystem name. This does not close descriptors already referring to the file.

```titan
function fs_unlink(loop: loop_t?, request: fs_t, path: string, callback: (function (fs_t): ())?): integer
```

**Inputs and outputs:** loop: INPUT initialized owning loop; accepted handles/requests retain it through retirement. Optional nil is meaningful; see contract.; request: INPUT/OUTPUT allocated nonpending request owner; FS submissions also require prior cleanup; accepted submission retains owner until its terminal callback returns; rejection owes no async callback.; path: INPUT immutable text/byte owner; native C-string conventions apply where the operation takes text. FS path strings remain retained until request cleanup; other synchronous borrows end when the call returns.; callback: INPUT ordinary callable, retained until the promised callback interval ends; callback argument owners are borrowed views retained through callback return. Optional nil is meaningful; see contract.

**Result, lifetime and cleanup:** Return type: integer. With callback nil, the call completes synchronously and returns its operation result. With a callback, a nonnegative submission accepts one deferred completion; a negative immediate return owes no callback. Read the terminal operation result with fs_get_result. A prepared dirty request requires fs_req_cleanup after synchronous completion, callback completion, or native rejection; a binding preflight rejection creates no new cleanup obligation.

**Callbacks:** optional-sync-or-deferred-once. the owning main Lua thread; timing is specified above

**Cancellation:** FS (accepted async only)

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L1487).


## fs_utime

`uv_fs_utime` — **canonical exported function**

Set path access/modification times in floating-point seconds, following symbolic links.

```titan
function fs_utime(loop: loop_t?, request: fs_t, path: string, atime: float, mtime: float, callback: (function (fs_t): ())?): integer
```

**Inputs and outputs:** loop: INPUT initialized owning loop; accepted handles/requests retain it through retirement. Optional nil is meaningful; see contract.; request: INPUT/OUTPUT allocated nonpending request owner; FS submissions also require prior cleanup; accepted submission retains owner until its terminal callback returns; rejection owes no async callback.; path: INPUT immutable text/byte owner; native C-string conventions apply where the operation takes text. FS path strings remain retained until request cleanup; other synchronous borrows end when the call returns.; atime: INPUT float value; checked native narrowing occurs before native ownership is accepted.; mtime: INPUT float value; checked native narrowing occurs before native ownership is accepted.; callback: INPUT ordinary callable, retained until the promised callback interval ends; callback argument owners are borrowed views retained through callback return. Optional nil is meaningful; see contract.

**Result, lifetime and cleanup:** Return type: integer. With callback nil, the call completes synchronously and returns its operation result. With a callback, a nonnegative submission accepts one deferred completion; a negative immediate return owes no callback. Read the terminal operation result with fs_get_result. A prepared dirty request requires fs_req_cleanup after synchronous completion, callback completion, or native rejection; a binding preflight rejection creates no new cleanup obligation.

**Callbacks:** optional-sync-or-deferred-once. the owning main Lua thread; timing is specified above

**Cancellation:** FS (accepted async only)

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L1603).


## fs_write

`uv_fs_write` — **canonical exported function**

Write borrowed buffer vectors. Offset -1 uses/updates the descriptor position; completion reports bytes written, which can be less than requested. Retain bytes unchanged through completion.

```titan
function fs_write(loop: loop_t?, request: fs_t, file: integer, buffers: {buf_t}, offset: integer, callback: (function (fs_t): ())?): integer
```

**Inputs and outputs:** loop: INPUT initialized owning loop; accepted handles/requests retain it through retirement. Optional nil is meaningful; see contract.; request: INPUT/OUTPUT allocated nonpending request owner; FS submissions also require prior cleanup; accepted submission retains owner until its terminal callback returns; rejection owes no async callback.; file: INPUT integer value; checked native narrowing occurs before native ownership is accepted.; buffers: INPUT byte owner or vector; immutable strings are valid only for input; async submission snapshots descriptors and retains owners, so Array edits cannot alter accepted I/O; do not mutate borrowed byte contents before completion.; offset: INPUT integer value; checked native narrowing occurs before native ownership is accepted.; callback: INPUT ordinary callable, retained until the promised callback interval ends; callback argument owners are borrowed views retained through callback return. Optional nil is meaningful; see contract.

**Result, lifetime and cleanup:** Return type: integer. With callback nil, the call completes synchronously and returns its operation result. With a callback, a nonnegative submission accepts one deferred completion; a negative immediate return owes no callback. Read the terminal operation result with fs_get_result. A prepared dirty request requires fs_req_cleanup after synchronous completion, callback completion, or native rejection; a binding preflight rejection creates no new cleanup obligation. Buffers input; offset -1 updates file offset; partial writes count bytes; retain immutable input owners through callback.

**Callbacks:** optional-sync-or-deferred-once. the owning main Lua thread; timing is specified above

**Cancellation:** FS (accepted async only)

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L1491).


## get_osfhandle

`uv_get_osfhandle` — **canonical exported function**

Convert a libuv integer file descriptor to its borrowed platform-native file handle token. No new native resource is acquired.

```titan
function get_osfhandle(file: integer): os_fd_t
```

**Inputs and outputs:** file: INPUT integer value; checked native narrowing occurs before native ownership is accepted.

**Result, lifetime and cleanup:** Return type: os_fd_t. Synchronous descriptor lookup. The os_fd_t token represents the existing native resource and does not extend or transfer its lifetime. On Windows it preserves HANDLE width; on Unix it represents the descriptor. Native invalid identifiers remain representable tokens, not a separate status return. No FS request or cleanup operation is involved.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L1288).


## open_osfhandle

`uv_open_osfhandle` — **canonical exported function**

Wrap a platform-native file handle in an integer descriptor using native ownership rules. On successful Windows conversion the descriptor owns the handle; do not close both representations independently.

```titan
function open_osfhandle(handle: os_fd_t): integer
```

**Inputs and outputs:** handle: INPUT exact-width borrowed native identifier token; collecting the token never closes/adopts its resource; see this operation's transfer rule.

**Result, lifetime and cleanup:** Return type: integer. Synchronous conversion. On Windows success transfers the supplied native handle into a CRT file descriptor; on Unix it returns the descriptor unchanged. This does not duplicate the resource. The os_fd_t is only a token; close the resource exactly once through its resulting owner. No FS request is involved.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L1289).

