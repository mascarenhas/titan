# threadpool API reference

Complete public example: [work_random](../examples/work_random.titan). See the
[example guide](../examples/README.md) for build/run commands and platform conditions.

The signatures use ordinary public `titan.uv` types. Read the [ownership contracts](../CONTRACT-NOTES.md) before submitting native work. Status values and callback results remain distinct.

## queue_work

`uv_queue_work` — **canonical exported function**

Queue C-only worker(arg) on libuv's shared worker pool. If accepted, it runs once unless successful queued cancellation skips it. Internal completion always returns to the loop thread; a nonnil after_work callback receives that completion. The explicit argument_owner keeps its GC graph alive through terminal callback return; nil is an externally owned borrow.

```titan
function queue_work(loop: loop_t, req: work_t, worker: foreign function (*void): void, arg: foreign *void, after_work: (function (work_t, integer): ())?, argument_owner: value): integer
```

**Inputs and outputs:** loop: INPUT initialized owning loop; accepted handles/requests retain it through retirement.; req: INPUT/OUTPUT allocated nonpending request owner; accepted submission retains owner until its terminal callback returns; rejection owes no async callback.; worker: INPUT C-only entry; no Lua/Titan execution from a native worker/once callback. Keep code loaded for every invocation.; arg: INPUT borrowed native address for explicit C-only/TLS interop; no automatic GC ownership. Retain its complete backing graph using the associated owner parameter or external lifetime.; after_work: INPUT ordinary callable, retained until the promised callback interval ends; callback argument owners are borrowed views retained through callback return. nil skips only the public completion call; the internal terminal callback still retires the request.; argument_owner: INPUT traced argument-owner graph retained through internal terminal completion and any public after_work callback return.

**Result, lifetime and cleanup:** Return type: integer. An accepted request invokes worker zero or one time: successful cancellation before work starts skips it. The binding always receives one terminal after-work completion on the owning loop, including cancellation, and retires native request bookkeeping. A nonnil public after_work callback is then invoked once; nil omits only that public call. Retain native arguments and argument_owner through internal completion and any public callback return. Workers are C-only and cannot enter Lua/Titan.

**Callbacks:** accepted request: worker zero-or-once; internal completion once; public after_work once only when nonnil. foreign-thread C-only entry plus owning-loop after-work

**Cancellation:** yes: accepted async request only; callback still required

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1211).

