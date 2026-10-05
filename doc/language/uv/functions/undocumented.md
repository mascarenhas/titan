# undocumented API reference

Complete public example: [loop_phases](../examples/loop_phases.titan). See the
[example guide](../examples/README.md) for build/run commands and platform conditions.

The signatures use ordinary public `titan.uv` types. Read the [ownership contracts](../CONTRACT-NOTES.md) before submitting native work. Status values and callback results remain distinct.

## loop_delete

`uv_loop_delete` — **not exported**

This native function has no direct public wrapper.

**Result, lifetime and cleanup:** Deprecated heap deletion helper does not own Titan packed loop storage. loop_close retires native state; GC later reclaims the Titan owner. Deprecated heap deletion helper does not own Titan packed loop storage. loop_close retires native state; GC later reclaims the Titan owner.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L304).

## loop_new

`uv_loop_new` — **not exported**

This native function has no direct public wrapper.

**Result, lifetime and cleanup:** Deprecated heap allocation helper conflicts with final packed Titan loop_t ownership. loop_t() followed by loop_init is the explicit public path. Deprecated heap allocation helper conflicts with final packed Titan loop_t ownership. loop_t() followed by loop_init is the explicit public path.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L298).
