# version API reference

Complete public example: [loop_phases](../examples/loop_phases.titan). See the
[example guide](../examples/README.md) for build/run commands and platform conditions.

The signatures use ordinary public `titan.uv` types. Read the [ownership contracts](../CONTRACT-NOTES.md) before submitting native work. Status values and callback results remain distinct.

## version

`uv_version` — **canonical exported function**

Return the packed native libuv version integer; it does not identify Titan's local patch bytes.

```titan
function version(): integer
```

**Result, lifetime and cleanup:** Return type: integer. Scalar/string snapshot of linked native provider version; version_string borrowed static bytes copied into Titan string.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L275).


## version_string

`uv_version_string` — **canonical exported function**

Return the native libuv version string; Titan's pinned local patch is part of the build contract, not this string.

```titan
function version_string(): string
```

**Result, lifetime and cleanup:** Return type: string. Scalar/string snapshot of linked native provider version; version_string borrowed static bytes copied into Titan string.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L276).

