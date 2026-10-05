# misc API reference

Complete public example: [dll_misc](../examples/dll_misc.titan). See the
[example guide](../examples/README.md) for build/run commands and platform conditions.

The signatures use ordinary public `titan.uv` types. Read the [ownership contracts](../CONTRACT-NOTES.md) before submitting native work. Status values and callback results remain distinct.

## available_parallelism

`uv_available_parallelism` — **canonical exported function**

Return the estimated amount of parallelism available to this process; this is not the number of libuv worker threads.

```titan
function available_parallelism(): integer
```

**Result, lifetime and cleanup:** Return type: integer. Synchronous. The returned scalar values need no explicit native cleanup.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1370).


## buf_init

`uv_buf_init` — **canonical exported function**

Create a read-only buf_t view over the first length bytes of an immutable string. The view retains the string and is not writable output storage.

```titan
function buf_init(base: string, length: integer): buf_t
```

**Inputs and outputs:** base: INPUT immutable byte string retained by the returned readonly buffer view, including embedded NUL bytes; the borrow outlives this constructor call.; length: INPUT integer value; checked native narrowing occurs before native ownership is accepted.

**Result, lifetime and cleanup:** Return type: buf_t. Constructs a readonly buf_t view of the first length bytes of a Titan string, retaining the string for the lifetime of that view. Requires 0 <= length <= string byte length and <= native UINT_MAX; out-of-range input raises before construction. Embedded NUL bytes are data. No native handle/request initialization or explicit cleanup is involved; readonly storage is valid only for input operations.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L511).


## chdir

`uv_chdir` — **canonical exported function**

Change the process working directory synchronously.

```titan
function chdir(dir: string): integer
```

**Inputs and outputs:** dir: INPUT immutable text/byte owner; native C-string conventions apply where the operation takes text. The binding retains or copies bytes for accepted asynchronous uses; synchronous borrows end on return.

**Result, lifetime and cleanup:** Return type: integer. Synchronous. The returned scalar values need no explicit native cleanup.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1845).


## clock_gettime

`uv_clock_gettime` — **canonical exported function**

Read the selected clock and return status plus a copied seconds/nanoseconds value.

```titan
function clock_gettime(clock: clock_id): (integer, timespec64_t?)
```

**Inputs and outputs:** clock: INPUT clock_id value.

**Result, lifetime and cleanup:** Return type: (integer, timespec64_t?). Synchronous. Status 0 returns an independent copied result record; nonzero status returns nil. Nested strings and records, when present, are copied as well. No explicit cleanup is required.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1852).


## cpu_info

`uv_cpu_info` — **canonical exported function**

Return status, a copied CPU-info Array, and native count. Model strings and counters are copied before the native allocation is freed.

```titan
function cpu_info(): (integer, {cpu_info_t}?, integer)
```

**Result, lifetime and cleanup:** Return type: (integer, {cpu_info_t}?, integer). Synchronous. Status 0 returns a fully copied Titan snapshot; a nonzero status returns nil for the value. Strings, nested records and Arrays are independent of native storage. Guaranteed deferred cleanup frees the matching native allocation before wrapper return, including copying failures. Callers perform no native free. The extra count is the number of reported logical CPUs, not the available_parallelism quota.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1371).


## cpumask_size

`uv_cpumask_size` — **canonical exported function**

Return the byte capacity required for native thread-affinity masks, or a native negative status.

```titan
function cpumask_size(): integer
```

**Result, lifetime and cleanup:** Return type: integer. Synchronous. The returned scalar values need no explicit native cleanup.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1373).


## cwd

`uv_cwd` — **canonical exported function**

Copy the working directory using capacity bytes and return status, optional text, and native required/actual length. Retry ENOBUFS explicitly when desired.

```titan
function cwd(capacity: integer): (integer, string?, integer)
```

**Inputs and outputs:** capacity: INPUT integer value; checked native narrowing occurs before native ownership is accepted.

**Result, lifetime and cleanup:** Return type: (integer, string?, integer). Synchronous. capacity allocates temporary writable bytes inside the binding. Success returns status 0, a copied string, and the native output length. A nonzero status returns nil text and the native size output, including a required size where that operation reports one on ENOBUFS. The copied string survives return without explicit cleanup.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1843).


## exepath

`uv_exepath` — **canonical exported function**

Copy the executable path using capacity bytes and retain the native actual-length/truncation behavior. Process argument setup is separate; no hidden capacity retry occurs.

```titan
function exepath(capacity: integer): (integer, string?, integer)
```

**Inputs and outputs:** capacity: INPUT integer value; checked native narrowing occurs before native ownership is accepted.

**Result, lifetime and cleanup:** Return type: (integer, string?, integer). Synchronous. capacity allocates temporary writable bytes inside the binding. Success returns status 0, a copied string, and the native output length. A nonzero status returns nil text and the native size output, including a required size where that operation reports one on ENOBUFS. The copied string survives return without explicit cleanup.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1841).


## free_cpu_info

`uv_free_cpu_info` — **internal cleanup after copied public result**

```titan
cpu_info owns this native free internally
```

**Result, lifetime and cleanup:** Public result is a copied Titan value; native allocation is freed by guaranteed deferred cleanup before returning. No public native allocation remains to free. Internal native cleanup only; no public callable is exported. The corresponding snapshot wrapper copies every exposed string, record and Array, then frees the native result before returning. The public copies remain valid and require no matching free.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1372).

## free_interface_addresses

`uv_free_interface_addresses` — **internal cleanup after copied public result**

```titan
interface_addresses owns this native free internally
```

**Result, lifetime and cleanup:** Public result is a copied Titan value; native allocation is freed by guaranteed deferred cleanup before returning. No public native allocation remains to free. Internal native cleanup only; no public callable is exported. The corresponding snapshot wrapper copies every exposed string, record and Array, then frees the native result before returning. The public copies remain valid and require no matching free.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1377).

## get_available_memory

`uv_get_available_memory` — **canonical exported function**

Return bytes of memory available to this process under native resource constraints.

```titan
function get_available_memory(): integer
```

**Result, lifetime and cleanup:** Return type: integer. Synchronous. The returned scalar values need no explicit native cleanup.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1850).


## get_constrained_memory

`uv_get_constrained_memory` — **canonical exported function**

Return the native memory constraint in bytes; zero can mean unknown or unconstrained rather than zero usable memory.

```titan
function get_constrained_memory(): integer
```

**Result, lifetime and cleanup:** Return type: integer. Synchronous. The returned scalar values need no explicit native cleanup.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1849).


## get_free_memory

`uv_get_free_memory` — **canonical exported function**

Return native free physical-memory bytes.

```titan
function get_free_memory(): integer
```

**Result, lifetime and cleanup:** Return type: integer. Synchronous. The returned scalar values need no explicit native cleanup.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1847).


## get_process_title

`uv_get_process_title` — **canonical exported function**

Copy the process title into capacity bytes and return `(status, title?)`. Low-level standalone clients should call setup_process_args first.

```titan
function get_process_title(capacity: integer): (integer, string?)
```

**Inputs and outputs:** capacity: INPUT integer value; checked native narrowing occurs before native ownership is accepted.

**Result, lifetime and cleanup:** Return type: (integer, string?). Synchronous. capacity allocates temporary native bytes internally; success returns 0 and a copied string, failure returns its native status and nil. Process-start argv setup must have been established through setup_process_args where required; importing low-level uv alone does not perform it.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1300).


## get_total_memory

`uv_get_total_memory` — **canonical exported function**

Return native total physical-memory bytes.

```titan
function get_total_memory(): integer
```

**Result, lifetime and cleanup:** Return type: integer. Synchronous. The returned scalar values need no explicit native cleanup.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1848).


## getrusage

`uv_getrusage` — **canonical exported function**

Return status and copied resource-usage counters for this process. Fields keep their native platform units; time fields use timeval seconds/microseconds.

```titan
function getrusage(): (integer, rusage_t?)
```

**Result, lifetime and cleanup:** Return type: (integer, rusage_t?). Synchronous. Status 0 returns an independent copied result record; nonzero status returns nil. Nested strings and records, when present, are copied as well. No explicit cleanup is required.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1326).


## getrusage_thread

`uv_getrusage_thread` — **canonical exported function**

Return status and copied resource-usage counters for the calling thread where supported.

```titan
function getrusage_thread(): (integer, rusage_t?)
```

**Result, lifetime and cleanup:** Return type: (integer, rusage_t?). Synchronous. Status 0 returns an independent copied result record; nonzero status returns nil. Nested strings and records, when present, are copied as well. No explicit cleanup is required.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1327).


## gettimeofday

`uv_gettimeofday` — **canonical exported function**

Return status and the wall-clock time as seconds/microseconds. Use a monotonic clock for elapsed-time measurement.

```titan
function gettimeofday(): (integer, timeval64_t?)
```

**Result, lifetime and cleanup:** Return type: (integer, timeval64_t?). Synchronous. Status 0 returns an independent copied result record; nonzero status returns nil. Nested strings and records, when present, are copied as well. No explicit cleanup is required.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1906).


## guess_handle

`uv_guess_handle` — **canonical exported function**

Classify an integer descriptor into the tagged native handle kind; the query does not adopt or close it.

```titan
function guess_handle(file: integer): handle_type
```

**Inputs and outputs:** file: INPUT integer value; checked native narrowing occurs before native ownership is accepted.

**Result, lifetime and cleanup:** Return type: handle_type. Synchronous. The returned scalar values need no explicit native cleanup.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L872).


## hrtime

`uv_hrtime` — **canonical exported function**

Return a high-resolution monotonic time in nanoseconds with an arbitrary origin. Differences measure elapsed time; it is not a wall-clock timestamp.

```titan
function hrtime(): integer
```

**Result, lifetime and cleanup:** Return type: integer. Synchronous. The returned scalar values need no explicit native cleanup.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1853).


## if_indextoiid

`uv_if_indextoiid` — **canonical exported function**

Copy the native interface identifier corresponding to an index into a writable buffer and return status and native length.

```titan
function if_indextoiid(index: integer, buffer: buf_t): (integer, integer)
```

**Inputs and outputs:** index: INPUT integer value; checked native narrowing occurs before native ownership is accepted.; buffer: OUTPUT writable buf_t; its byte length is capacity and native writes complete synchronously

**Result, lifetime and cleanup:** Return type: (integer, integer). Requires a writable buf_t whose length supplies native capacity. Returns status and the actual/required size from a synchronous native write. On success to_string(size) creates a separate string copy. No asynchronous borrow or native free remains.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1837).


## if_indextoname

`uv_if_indextoname` — **canonical exported function**

Copy an interface name corresponding to an index into a writable buffer and return status and native length.

```titan
function if_indextoname(index: integer, buffer: buf_t): (integer, integer)
```

**Inputs and outputs:** index: INPUT integer value; checked native narrowing occurs before native ownership is accepted.; buffer: OUTPUT writable buf_t; its byte length is capacity and native writes complete synchronously

**Result, lifetime and cleanup:** Return type: (integer, integer). Requires a writable buf_t whose length supplies native capacity. Returns status and the actual/required size from a synchronous native write. On success to_string(size) creates a separate string copy. No asynchronous borrow or native free remains.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1834).


## inet_ntop

`uv_inet_ntop` — **canonical exported function**

Convert copied binary IPv4/IPv6 address bytes into presentation text for address family af.

```titan
function inet_ntop(af: integer, source: string): (integer, string?)
```

**Inputs and outputs:** af: INPUT integer value; checked native narrowing occurs before native ownership is accepted.; source: INPUT immutable text/byte owner; native C-string conventions apply where the operation takes text. The binding retains or copies bytes for accepted asynchronous uses; synchronous borrows end on return.

**Result, lifetime and cleanup:** Return type: (integer, string?). Synchronous. Success returns 0 and a copied Titan string; failure returns the native status and nil. inet_pton produces binary address bytes; the name and ntop operations produce text. No native allocation escapes or needs explicit cleanup.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1803).


## inet_pton

`uv_inet_pton` — **canonical exported function**

Parse presentation text into copied binary IPv4/IPv6 bytes for address family af.

```titan
function inet_pton(af: integer, source: string): (integer, string?)
```

**Inputs and outputs:** af: INPUT integer value; checked native narrowing occurs before native ownership is accepted.; source: INPUT immutable text/byte owner; native C-string conventions apply where the operation takes text. The binding retains or copies bytes for accepted asynchronous uses; synchronous borrows end on return.

**Result, lifetime and cleanup:** Return type: (integer, string?). Synchronous. Success returns 0 and a copied Titan string; failure returns the native status and nil. inet_pton produces binary address bytes; the name and ntop operations produce text. No native allocation escapes or needs explicit cleanup.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1804).


## interface_addresses

`uv_interface_addresses` — **canonical exported function**

Return status, a copied interface-address Array, and native count. Each entry survives the internal native free.

```titan
function interface_addresses(): (integer, {interface_address_t}?, integer)
```

**Result, lifetime and cleanup:** Return type: (integer, {interface_address_t}?, integer). Synchronous. Status 0 returns a fully copied Titan snapshot; a nonzero status returns nil for the value. Strings, nested records and Arrays are independent of native storage. Guaranteed deferred cleanup frees the matching native allocation before wrapper return, including copying failures. Callers perform no native free. The extra count is the number of copied interface entries; physical-address bytes and sockaddr values are copies.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1375).


## ip4_addr

`uv_ip4_addr` — **canonical exported function**

Parse numeric IPv4 text and port 0..65535 into a copied typed sockaddr_t.

```titan
function ip4_addr(ip: string, port: integer): (integer, sockaddr_t?)
```

**Inputs and outputs:** ip: INPUT immutable text/byte owner; native C-string conventions apply where the operation takes text. The binding retains or copies bytes for accepted asynchronous uses; synchronous borrows end on return.; port: INPUT integer value; checked native narrowing occurs before native ownership is accepted.

**Result, lifetime and cleanup:** Return type: (integer, sockaddr_t?). Synchronous. Success returns 0 and an independently owned sockaddr_t copy; failure returns the native status and nil. No handle or request lifetime is created.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1796).


## ip4_name

`uv_ip4_name` — **canonical exported function**

Return status and numeric IPv4 text for a compatible typed address.

```titan
function ip4_name(address: sockaddr_t): (integer, string?)
```

**Inputs and outputs:** address: INPUT complete typed address owner; no sockaddr pointer/header required; constructor/accessors encode family/port/bytes. Native submission consumes or copies address during the call.

**Result, lifetime and cleanup:** Return type: (integer, string?). Synchronous. Success returns 0 and a copied Titan string; failure returns the native status and nil. inet_pton produces binary address bytes; the name and ntop operations produce text. No native allocation escapes or needs explicit cleanup.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1799).


## ip6_addr

`uv_ip6_addr` — **canonical exported function**

Parse numeric IPv6 text and port 0..65535 into a copied typed sockaddr_t, retaining supported scope information.

```titan
function ip6_addr(ip: string, port: integer): (integer, sockaddr_t?)
```

**Inputs and outputs:** ip: INPUT immutable text/byte owner; native C-string conventions apply where the operation takes text. The binding retains or copies bytes for accepted asynchronous uses; synchronous borrows end on return.; port: INPUT integer value; checked native narrowing occurs before native ownership is accepted.

**Result, lifetime and cleanup:** Return type: (integer, sockaddr_t?). Synchronous. Success returns 0 and an independently owned sockaddr_t copy; failure returns the native status and nil. No handle or request lifetime is created.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1797).


## ip6_name

`uv_ip6_name` — **canonical exported function**

Return status and numeric IPv6 text for a compatible typed address.

```titan
function ip6_name(address: sockaddr_t): (integer, string?)
```

**Inputs and outputs:** address: INPUT complete typed address owner; no sockaddr pointer/header required; constructor/accessors encode family/port/bytes. Native submission consumes or copies address during the call.

**Result, lifetime and cleanup:** Return type: (integer, string?). Synchronous. Success returns 0 and a copied Titan string; failure returns the native status and nil. inet_pton produces binary address bytes; the name and ntop operations produce text. No native allocation escapes or needs explicit cleanup.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1800).


## ip_name

`uv_ip_name` — **canonical exported function**

Return status and numeric IPv4/IPv6 text according to the typed address family.

```titan
function ip_name(address: sockaddr_t): (integer, string?)
```

**Inputs and outputs:** address: INPUT complete typed address owner; no sockaddr pointer/header required; constructor/accessors encode family/port/bytes. Native submission consumes or copies address during the call.

**Result, lifetime and cleanup:** Return type: (integer, string?). Synchronous. Success returns 0 and a copied Titan string; failure returns the native status and nil. inet_pton produces binary address bytes; the name and ntop operations produce text. No native allocation escapes or needs explicit cleanup.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1801).


## library_shutdown

`uv_library_shutdown` — **not exported**

This native function has no direct public wrapper.

**Result, lifetime and cleanup:** Once-only terminal process-global shutdown forbids every later libuv call; a reusable module cannot prove all libuv users are quiescent. Once-only terminal process-global shutdown forbids every later libuv call; a reusable module cannot prove all libuv users are quiescent.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L283).

## loadavg

`uv_loadavg` — **canonical exported function**

Return native one-, five-, and fifteen-minute load averages. Native platforms without these measurements retain libuv's zero values.

```titan
function loadavg(): (float, float, float)
```

**Result, lifetime and cleanup:** Return type: (float, float, float). Synchronous. The returned scalar values need no explicit native cleanup.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1752).


## os_environ

`uv_os_environ` — **canonical exported function**

Copy all native environment entries into a Titan Array and return status/Array/count. The binding frees the native snapshot before return.

```titan
function os_environ(): (integer, {env_item_t}?, integer)
```

**Result, lifetime and cleanup:** Return type: (integer, {env_item_t}?, integer). Synchronous. Status 0 returns a fully copied Titan snapshot; a nonzero status returns nil for the value. Strings, nested records and Arrays are independent of native storage. Guaranteed deferred cleanup frees the matching native allocation before wrapper return, including copying failures. Callers perform no native free. The extra count is the number of copied environment entries; later environment changes do not mutate this snapshot.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1385).


## os_free_environ

`uv_os_free_environ` — **internal cleanup after copied public result**

```titan
os_environ owns this native free internally
```

**Result, lifetime and cleanup:** Public result is a copied Titan value; native allocation is freed by guaranteed deferred cleanup before returning. No public native allocation remains to free. Internal native cleanup only; no public callable is exported. The corresponding snapshot wrapper copies every exposed string, record and Array, then frees the native result before returning. The public copies remain valid and require no matching free.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1386).

## os_free_group

`uv_os_free_group` — **internal cleanup after copied public result**

```titan
os_get_group owns this native free internally
```

**Result, lifetime and cleanup:** Public result is a copied Titan value; native allocation is freed by guaranteed deferred cleanup before returning. No public native allocation remains to free. Internal native cleanup only; no public callable is exported. The corresponding snapshot wrapper copies every exposed string, record and Array, then frees the native result before returning. The public copies remain valid and require no matching free.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1335).

## os_free_passwd

`uv_os_free_passwd` — **internal cleanup after copied public result**

```titan
os_get_passwd / os_get_passwd2 owns this native free internally
```

**Result, lifetime and cleanup:** Public result is a copied Titan value; native allocation is freed by guaranteed deferred cleanup before returning. No public native allocation remains to free. Internal native cleanup only; no public callable is exported. The corresponding snapshot wrapper copies every exposed string, record and Array, then frees the native result before returning. The public copies remain valid and require no matching free.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1332).

## os_get_group

`uv_os_get_group` — **canonical exported function**

Look up gid and return a copied group record including members; native snapshot storage is freed internally.

```titan
function os_get_group(gid: integer): (integer, group_t?)
```

**Inputs and outputs:** gid: INPUT integer value; checked native narrowing occurs before native ownership is accepted.

**Result, lifetime and cleanup:** Return type: (integer, group_t?). Synchronous. Status 0 returns a fully copied Titan snapshot; a nonzero status returns nil for the value. Strings, nested records and Arrays are independent of native storage. Guaranteed deferred cleanup frees the matching native allocation before wrapper return, including copying failures. Callers perform no native free. The member list is a copied Array of strings. Unsupported platforms retain their native error status.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1334).


## os_get_passwd

`uv_os_get_passwd` — **canonical exported function**

Look up the current effective user and return a copied passwd record; native strings are freed internally.

```titan
function os_get_passwd(): (integer, passwd_t?)
```

**Result, lifetime and cleanup:** Return type: (integer, passwd_t?). Synchronous. Status 0 returns a fully copied Titan snapshot; a nonzero status returns nil for the value. Strings, nested records and Arrays are independent of native storage. Guaranteed deferred cleanup frees the matching native allocation before wrapper return, including copying failures. Callers perform no native free. shell may be nil on Windows.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1331).


## os_get_passwd2

`uv_os_get_passwd2` — **canonical exported function**

Look up uid and return a copied passwd record; native strings are freed internally.

```titan
function os_get_passwd2(uid: integer): (integer, passwd_t?)
```

**Inputs and outputs:** uid: INPUT integer value; checked native narrowing occurs before native ownership is accepted.

**Result, lifetime and cleanup:** Return type: (integer, passwd_t?). Synchronous. Status 0 returns a fully copied Titan snapshot; a nonzero status returns nil for the value. Strings, nested records and Arrays are independent of native storage. Guaranteed deferred cleanup frees the matching native allocation before wrapper return, including copying failures. Callers perform no native free. The UID-specific lookup preserves unsupported-platform error statuses.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1333).


## os_getenv

`uv_os_getenv` — **canonical exported function**

Read one environment variable into capacity bytes, returning status, optional value, and native required/actual length. Missing and empty values are distinct.

```titan
function os_getenv(name: string, capacity: integer): (integer, string?, integer)
```

**Inputs and outputs:** name: INPUT immutable text/byte owner; native C-string conventions apply where the operation takes text. The binding retains or copies bytes for accepted asynchronous uses; synchronous borrows end on return.; capacity: INPUT integer value; checked native narrowing occurs before native ownership is accepted.

**Result, lifetime and cleanup:** Return type: (integer, string?, integer). Synchronous. capacity allocates temporary writable bytes inside the binding. Success returns status 0, a copied string, and the native output length. A nonzero status returns nil text and the native size output, including a required size where that operation reports one on ENOBUFS. The copied string survives return without explicit cleanup. Environment reads and mutation require application synchronization across native threads.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1387).


## os_gethostname

`uv_os_gethostname` — **canonical exported function**

Copy the host name into capacity bytes and preserve native required/actual length.

```titan
function os_gethostname(capacity: integer): (integer, string?, integer)
```

**Inputs and outputs:** capacity: INPUT integer value; checked native narrowing occurs before native ownership is accepted.

**Result, lifetime and cleanup:** Return type: (integer, string?, integer). Synchronous. capacity allocates temporary writable bytes inside the binding. Success returns status 0, a copied string, and the native output length. A nonzero status returns nil text and the native size output, including a required size where that operation reports one on ENOBUFS. The copied string survives return without explicit cleanup.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1402).


## os_getpid

`uv_os_getpid` — **canonical exported function**

Return this process's native PID.

```titan
function os_getpid(): integer
```

**Result, lifetime and cleanup:** Return type: integer. Synchronous. The returned scalar values need no explicit native cleanup.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1336).


## os_getppid

`uv_os_getppid` — **canonical exported function**

Return the native parent PID.

```titan
function os_getppid(): integer
```

**Result, lifetime and cleanup:** Return type: integer. Synchronous. The returned scalar values need no explicit native cleanup.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1337).


## os_getpriority

`uv_os_getpriority` — **canonical exported function**

Return status and numeric priority for pid; priority is a data value, not a bitmask.

```titan
function os_getpriority(pid: integer): (integer, integer?)
```

**Inputs and outputs:** pid: INPUT integer value; checked native narrowing occurs before native ownership is accepted.

**Result, lifetime and cleanup:** Return type: (integer, integer?). Synchronous. Status 0 returns the scalar result; nonzero status returns nil for that result. No native resource or cleanup obligation is created.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1356).


## os_homedir

`uv_os_homedir` — **canonical exported function**

Copy the native home-directory path using explicit byte capacity and return native required/actual length.

```titan
function os_homedir(capacity: integer): (integer, string?, integer)
```

**Inputs and outputs:** capacity: INPUT integer value; checked native narrowing occurs before native ownership is accepted.

**Result, lifetime and cleanup:** Return type: (integer, string?, integer). Synchronous. capacity allocates temporary writable bytes inside the binding. Success returns status 0, a copied string, and the native output length. A nonzero status returns nil text and the native size output, including a required size where that operation reports one on ENOBUFS. The copied string survives return without explicit cleanup.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1329).


## os_setenv

`uv_os_setenv` — **canonical exported function**

Set a process environment variable to the supplied text value.

```titan
function os_setenv(name: string, value: string): integer
```

**Inputs and outputs:** name: INPUT immutable text/byte owner; native C-string conventions apply where the operation takes text. The binding retains or copies bytes for accepted asynchronous uses; synchronous borrows end on return.; value: INPUT immutable text/byte owner; native C-string conventions apply where the operation takes text. The binding retains or copies bytes for accepted asynchronous uses; synchronous borrows end on return.

**Result, lifetime and cleanup:** Return type: integer. Synchronous process-environment mutation with native status. Inputs are borrowed for the call; no owner or cleanup obligation escapes. Coordinate access with other native threads.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1388).


## os_setpriority

`uv_os_setpriority` — **canonical exported function**

Set the numeric process priority for pid subject to platform permissions/ranges.

```titan
function os_setpriority(pid: integer, priority: integer): integer
```

**Inputs and outputs:** pid: INPUT integer value; checked native narrowing occurs before native ownership is accepted.; priority: INPUT integer value; checked native narrowing occurs before native ownership is accepted.

**Result, lifetime and cleanup:** Return type: integer. Synchronous. The returned scalar values need no explicit native cleanup.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1357).


## os_tmpdir

`uv_os_tmpdir` — **canonical exported function**

Copy the native temporary-directory path using explicit byte capacity and return native required/actual length.

```titan
function os_tmpdir(capacity: integer): (integer, string?, integer)
```

**Inputs and outputs:** capacity: INPUT integer value; checked native narrowing occurs before native ownership is accepted.

**Result, lifetime and cleanup:** Return type: (integer, string?, integer). Synchronous. capacity allocates temporary writable bytes inside the binding. Success returns status 0, a copied string, and the native output length. A nonzero status returns nil text and the native size output, including a required size where that operation reports one on ENOBUFS. The copied string survives return without explicit cleanup.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1330).


## os_uname

`uv_os_uname` — **canonical exported function**

Return status and a copied OS identity record.

```titan
function os_uname(): (integer, utsname_t?)
```

**Result, lifetime and cleanup:** Return type: (integer, utsname_t?). Synchronous. Status 0 returns an independent copied result record; nonzero status returns nil. Nested strings and records, when present, are copied as well. No explicit cleanup is required.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1404).


## os_unsetenv

`uv_os_unsetenv` — **canonical exported function**

Remove a process environment variable.

```titan
function os_unsetenv(name: string): integer
```

**Inputs and outputs:** name: INPUT immutable text/byte owner; native C-string conventions apply where the operation takes text. The binding retains or copies bytes for accepted asynchronous uses; synchronous borrows end on return.

**Result, lifetime and cleanup:** Return type: integer. Synchronous process-environment mutation with native status. The name is borrowed for the call; no owner or cleanup obligation escapes. Coordinate access with other native threads.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1389).


## print_active_handles

`uv_print_active_handles` — **not exported**

This native function has no direct public wrapper.

**Result, lifetime and cleanup:** Diagnostic FILE* API has no approved public FILE owner. walk plus is_active supplies typed inspection without inventing FILE* ownership. Diagnostic FILE* API has no approved public FILE owner. walk plus is_active supplies typed inspection without inventing FILE* ownership.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L502).

## print_all_handles

`uv_print_all_handles` — **not exported**

This native function has no direct public wrapper.

**Result, lifetime and cleanup:** Diagnostic FILE* API has no approved public FILE owner. walk supplies typed handle inspection without inventing FILE* ownership. Diagnostic FILE* API has no approved public FILE owner. walk supplies typed handle inspection without inventing FILE* ownership.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L501).

## random

`uv_random` — **canonical exported function**

Fill writable storage with length random bytes. A nil callback selects synchronous operation; async operation requires a request/loop and retains the buffer until completion.

```titan
function random(loop: loop_t?, request: random_t?, buffer: buf_t, length: integer, flags: integer, callback: (function (random_t, integer, buf_t, integer): ())?): integer
```

**Inputs and outputs:** loop: INPUT initialized owning loop; accepted handles/requests retain it through retirement. Optional nil is meaningful; see contract.; request: INPUT/OUTPUT allocated nonpending request owner; accepted submission retains owner until its terminal callback returns; rejection owes no async callback. Optional nil is meaningful; see contract.; buffer: OUTPUT writable owned byte storage; caller allocates capacity, native operation writes bytes; accepted async borrow retained through terminal callback/cleanup.; length: INPUT integer value; checked native narrowing occurs before native ownership is accepted.; flags: INPUT integer value; checked native narrowing occurs before native ownership is accepted.; callback: INPUT ordinary callable, retained until the promised callback interval ends; the request and buffer views remain retained through callback return; a saved buffer view retains its bytes. Optional nil is meaningful; see contract.

**Result, lifetime and cleanup:** Return type: integer. callback nil selects synchronous filling of the writable buf_t; loop/request may then be nil. Otherwise loop and request must be supplied, and a nonnegative submission retains the destination through one terminal callback; negative immediate rejection owes none. flags must be 0 and length must fit the buffer. Cancellation still owes completion. The public buffer argument is an owner-retaining view and remains valid if saved after callback return.

**Callbacks:** optional-sync-or-deferred-once. the owning main Lua thread; timing is specified above

**Cancellation:** yes: accepted async request only; callback still required

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1819).


## replace_allocator

`uv_replace_allocator` — **not exported**

This native function has no direct public wrapper.

**Result, lifetime and cleanup:** Process-global before-first-use or globally quiescent allocator policy and thread-safe C-only hooks need ownership outside a reusable Lua-state module. Process-global before-first-use or globally quiescent allocator policy and thread-safe C-only hooks need ownership outside a reusable Lua-state module.

**Callbacks:** none. C-only potentially foreign thread

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L285).

## resident_set_memory

`uv_resident_set_memory` — **canonical exported function**

Return status and the process's resident-memory size in bytes.

```titan
function resident_set_memory(): (integer, integer?)
```

**Result, lifetime and cleanup:** Return type: (integer, integer?). Synchronous. Status 0 returns the scalar result; nonzero status returns nil for that result. No native resource or cleanup obligation is created.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1302).


## set_process_title

`uv_set_process_title` — **canonical exported function**

Set the process title synchronously after process-argument setup. Availability and effects on OS displays are platform-specific.

```titan
function set_process_title(title: string): integer
```

**Inputs and outputs:** title: INPUT immutable text/byte owner; native C-string conventions apply where the operation takes text. The binding retains or copies bytes for accepted asynchronous uses; synchronous borrows end on return.

**Result, lifetime and cleanup:** Return type: integer. Synchronous. The returned scalar values need no explicit native cleanup.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1301).


## setup_args

`uv_setup_args` — **not exported**

This native function has no direct public wrapper.

**Result, lifetime and cleanup:** Requires true process-start argv/title memory and once-only global setup. An Array of copied Titan strings does not satisfy that memory contract. Requires true process-start argv/title memory and once-only global setup. An Array of copied Titan strings does not satisfy that memory contract.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1299).

The separate [`setup_process_args()`](../supplemental.md#setup_process_args) helper configures only original generated-entrypoint arguments. It cannot substitute caller-created strings for process-start storage.

## sleep

`uv_sleep` — **canonical exported function**

Block the calling OS thread for msec milliseconds. Use timer.sleep for a cooperative async Task delay.

```titan
function sleep(msec: integer)
```

**Inputs and outputs:** msec: INPUT integer value; checked native narrowing occurs before native ownership is accepted.

**Result, lifetime and cleanup:** Return type: (). Synchronous. The returned scalar values need no explicit native cleanup.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1854).


## uptime

`uv_uptime` — **canonical exported function**

Return status and system uptime in floating-point seconds.

```titan
function uptime(): (integer, float?)
```

**Result, lifetime and cleanup:** Return type: (integer, float?). Synchronous. Status 0 returns the scalar result; nonzero status returns nil for that result. No native resource or cleanup obligation is created.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1303).


## utf16_length_as_wtf8

`uv_utf16_length_as_wtf8` — **canonical exported function**

Measure WTF-8 bytes required for the UTF-16 input units. Length is a code-unit count, or -1 for NUL termination; the result excludes a terminator.

```titan
function utf16_length_as_wtf8(units: {integer}, length: integer): integer
```

**Inputs and outputs:** units: INPUT {integer} value; checked native narrowing occurs before native ownership is accepted.; length: INPUT integer value; checked native narrowing occurs before native ownership is accepted.

**Result, lifetime and cleanup:** Return type: integer. The binding copies and checks UTF-16 input units; length is a count within the Array or -1 for NUL termination. Returns the required WTF-8 byte count excluding the terminating NUL. No native allocation escapes.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1978).


## utf16_to_wtf8

`uv_utf16_to_wtf8` — **canonical exported function**

Convert UTF-16 input units into copied WTF-8 bytes, with an optional explicit output capacity; return status, optional output, and native output length.

```titan
function utf16_to_wtf8(units: {integer}, length: integer, capacity: integer?): (integer, string?, integer)
```

**Inputs and outputs:** units: INPUT {integer} value; checked native narrowing occurs before native ownership is accepted.; length: INPUT integer value; checked native narrowing occurs before native ownership is accepted.; capacity: INPUT integer? value; checked native narrowing occurs before native ownership is accepted.

**Result, lifetime and cleanup:** Return type: (integer, string?, integer). The binding copies and checks UTF-16 input units; length is an explicit count or -1 for NUL termination. capacity nil requests a length-only result: status, nil, required byte count. A nonnil capacity allocates temporary writable bytes internally; success returns a copied string and actual byte count. ENOBUFS returns a copied capacity-byte prefix and the native required size. Other failures return nil text. No public native allocation or free is involved.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1980).


## wtf8_length_as_utf16

`uv_wtf8_length_as_utf16` — **canonical exported function**

Measure the UTF-16 code units needed for WTF-8 text using native conversion semantics.

```titan
function wtf8_length_as_utf16(text: string): integer
```

**Inputs and outputs:** text: INPUT immutable text/byte owner; native C-string conventions apply where the operation takes text. The binding retains or copies bytes for accepted asynchronous uses; synchronous borrows end on return.

**Result, lifetime and cleanup:** Return type: integer. Examines NUL-terminated WTF-8 text synchronously. Returns the UTF-16 unit count including its terminating NUL, or -1 for malformed input. No native allocation escapes.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1984).


## wtf8_to_utf16

`uv_wtf8_to_utf16` — **canonical exported function**

Convert exactly length bytes of WTF-8 text to copied UTF-16 code units. This is a byte count, not a Unicode character count.

```titan
function wtf8_to_utf16(text: string, length: integer): {integer}
```

**Inputs and outputs:** text: INPUT immutable text/byte owner; native C-string conventions apply where the operation takes text. The binding retains or copies bytes for accepted asynchronous uses; synchronous borrows end on return.; length: INPUT integer value; checked native narrowing occurs before native ownership is accepted.

**Result, lifetime and cleanup:** Return type: {integer}. The binding first validates the NUL-terminated WTF-8 text and computes the native required UTF-16 length. Invalid input or a supplied length different from that requirement raises before conversion. Success returns an independent Array of code units, including the terminating NUL. Temporary native storage is internal.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1985).

