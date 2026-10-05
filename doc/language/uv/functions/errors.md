# errors API reference

Complete public example: [loop_phases](../examples/loop_phases.titan). See the
[example guide](../examples/README.md) for build/run commands and platform conditions.

The signatures use ordinary public `titan.uv` types. Read the [ownership contracts](../CONTRACT-NOTES.md) before submitting native work. Status values and callback results remain distinct.

## err_name

`uv_err_name` — **canonical exported function**

Copy the symbolic name for a libuv error code, such as ENOENT. Pass a libuv status, not an arbitrary platform errno.

```titan
function err_name(err: integer): string
```

**Inputs and outputs:** err: INPUT integer value; checked native narrowing occurs before native ownership is accepted.

**Result, lifetime and cleanup:** Return type: string. Synchronous. Returns an ordinary copied Titan string for a libuv status code. The copy survives future calls; no native free is exposed.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L428).


## err_name_r

`uv_err_name_r` — **canonical exported function**

Copy the symbolic libuv error name through a temporary native buffer of capacity bytes. The returned Titan string owns its bytes; zero capacity yields an empty string.

```titan
function err_name_r(err: integer, capacity: integer): string
```

**Inputs and outputs:** err: INPUT integer value; checked native narrowing occurs before native ownership is accepted.; capacity: INPUT integer value; checked native narrowing occurs before native ownership is accepted.

**Result, lifetime and cleanup:** Return type: string. Synchronous. capacity selects a temporary native buffer allocated inside the binding. Returns a copied Titan string; zero capacity yields an empty string. No caller-supplied native pointer or explicit free is involved.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L429).


## strerror

`uv_strerror` — **canonical exported function**

Copy human-readable text for a libuv error code.

```titan
function strerror(err: integer): string
```

**Inputs and outputs:** err: INPUT integer value; checked native narrowing occurs before native ownership is accepted.

**Result, lifetime and cleanup:** Return type: string. Synchronous. Returns an ordinary copied Titan string for a libuv status code. The copy survives future calls; no native free is exposed.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L425).


## strerror_r

`uv_strerror_r` — **canonical exported function**

Copy libuv error text through a temporary native buffer of capacity bytes. The returned Titan string owns its bytes; zero capacity yields an empty string.

```titan
function strerror_r(err: integer, capacity: integer): string
```

**Inputs and outputs:** err: INPUT integer value; checked native narrowing occurs before native ownership is accepted.; capacity: INPUT integer value; checked native narrowing occurs before native ownership is accepted.

**Result, lifetime and cleanup:** Return type: string. Synchronous. capacity selects a temporary native buffer allocated inside the binding. Returns a copied Titan string; zero capacity yields an empty string. No caller-supplied native pointer or explicit free is involved.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L426).


## translate_sys_error

`uv_translate_sys_error` — **canonical exported function**

Convert a native system error to the libuv error domain. On Windows this expects the relevant Win32 error domain, not arbitrary CRT errno values.

```titan
function translate_sys_error(sys_errno: integer): integer
```

**Inputs and outputs:** sys_errno: INPUT integer value; checked native narrowing occurs before native ownership is accepted.

**Result, lifetime and cleanup:** Return type: integer. Synchronous conversion of a platform system error to the libuv error domain. On Windows pass the appropriate Win32 error, not an arbitrary CRT errno. The scalar result needs no cleanup.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L423).

