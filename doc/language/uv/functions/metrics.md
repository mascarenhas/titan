# metrics API reference

Complete public example: [loop_phases](../examples/loop_phases.titan). See the
[example guide](../examples/README.md) for build/run commands and platform conditions.

The signatures use ordinary public `titan.uv` types. Read the [ownership contracts](../CONTRACT-NOTES.md) before submitting native work. Status values and callback results remain distinct.

## metrics_idle_time

`uv_metrics_idle_time` — **canonical exported function**

Return nanoseconds spent idle in the loop's I/O provider; enable the metrics option before collecting this value.

```titan
function metrics_idle_time(loop: loop_t): integer
```

**Inputs and outputs:** loop: INPUT initialized owning loop; accepted handles/requests retain it through retirement.

**Result, lifetime and cleanup:** Return type: integer. Requires an initialized loop; otherwise raises. Returns accumulated provider idle time in nanoseconds. Enable LOOP_METRICS_IDLE_TIME through loop_configure before relying on collection; the native unsigned counter uses the documented integer bit channel.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1415).


## metrics_info

`uv_metrics_info` — **canonical exported function**

Copy native loop iteration/event counters into metrics_t and return `(status, value?)`.

```titan
function metrics_info(loop: loop_t): (integer, metrics_t?)
```

**Inputs and outputs:** loop: INPUT initialized owning loop; accepted handles/requests retain it through retirement.

**Result, lifetime and cleanup:** Return type: (integer, metrics_t?). Requires an initialized loop. Returns status and an independent copied metrics_t on success, or nil on failure. Later loop activity does not mutate the snapshot.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1414).

