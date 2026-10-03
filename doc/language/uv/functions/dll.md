# dll API reference

Complete public example: [dll_misc](../examples/dll_misc.titan). See the
[example guide](../examples/README.md) for build/run commands and platform conditions.

lib_t owns one native open attempt. Both successful and failed dlopen attempts require dlclose, including failure-owned error text. Close is terminal; symbol_t retains its library and exposes its pointer only while that library remains open. Copy dlerror immediately. Ordinary DLL clients need no libuv FFI.

## dlclose

`uv_dlclose` — **canonical exported function**

Retire the library lifetime, including native error storage from a failed open. Existing symbol tokens become unusable; construct a new owner for another image.

```titan
function dlclose(library: lib_t)
```

**Inputs and outputs:** library: INPUT/OUTPUT library owner; dlopen requires fresh storage and both success and failed native open require dlclose; close is terminal.

**Result, lifetime and cleanup:** Return type: (). Packed library owner; errors via dlerror and 0/-1 convention; copied error text before state changes; loaded symbol lifetime bounded by dlclose.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L1843).


## dlerror

`uv_dlerror` — **canonical exported function**

Copy the library's last native loader diagnostic while its lifetime remains open.

```titan
function dlerror(library: lib_t): string
```

**Inputs and outputs:** library: INPUT/OUTPUT library owner; dlopen requires fresh storage and both success and failed native open require dlclose; close is terminal.

**Result, lifetime and cleanup:** Return type: string. Packed library owner; errors via dlerror and 0/-1 convention; copied error text before state changes; loaded symbol lifetime bounded by dlclose.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L1845).


## dlopen

`uv_dlopen` — **canonical exported function**

Open the named dynamic library into one fresh lib_t owner. Both a successful native open and failed native attempt require dlclose to release library/error storage.

```titan
function dlopen(filename: string, library: lib_t): integer
```

**Inputs and outputs:** filename: INPUT immutable text/byte owner; native C-string conventions apply where the operation takes text. The binding retains or copies bytes for accepted asynchronous uses; synchronous borrows end on return.; library: INPUT/OUTPUT library owner; dlopen requires fresh storage and both success and failed native open require dlclose; close is terminal.

**Result, lifetime and cleanup:** Return type: integer. Packed library owner; errors via dlerror and 0/-1 convention; copied error text before state changes; loaded symbol lifetime bounded by dlclose. Initializes library output even on failure with error string; dlclose is required to clean initialized state after both success and failure. No libuv error-status convention assumed for dlopen (returns 0/-1).

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L1842).


## dlsym

`uv_dlsym` — **canonical exported function**

Look up a named symbol and return `(status, symbol?)`. The symbol is borrowed from this library lifetime and must not be used after dlclose.

```titan
function dlsym(library: lib_t, name: string): (integer, symbol_t?)
```

**Inputs and outputs:** library: INPUT/OUTPUT library owner; dlopen requires fresh storage and both success and failed native open require dlclose; close is terminal.; name: INPUT immutable text/byte owner; native C-string conventions apply where the operation takes text. The binding retains or copies bytes for accepted asynchronous uses; synchronous borrows end on return.

**Result, lifetime and cleanup:** Return type: (integer, symbol_t?). Returns 0 and a symbol_t on success, or -1 and nil on lookup failure; consult dlerror for copied error text. The symbol retains its lib_t owner, but explicit dlclose still ends native code/data validity. The symbol record may remain referenced after close; pointer() then raises. A previously extracted foreign pointer must never be used after dlclose.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L1844).

