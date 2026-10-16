# Transfer policy implementation

`titan/transfer.titan` owns `TransferValue`, reflected custom-record hook
selection, and semantic policy projection. It imports reflection and protobuf
without UV or async. `async` exports a transparent alias, preserving the public
spelling while letting UV owner hooks depend on the policy below the scheduler.

The native graph runtime and Lua worker bootstrap resolve the canonical
`titan.transfer.TransferValue` descriptor. The existing closure graph,
module capability, mutable-cell identity, and cycle rules are unchanged.
See [the async implementation](libuv-runtime.md#cross-state-receiver-ownership)
and [Lua state loading](lua-library.md) for delivery and reconstruction.

Resource hooks are ordinary reflected custom-record hooks. They implement the
explicit manual ownership contract: preflight before detachment, adoption once,
and caller-owned recovery after delivery failure. There is no global resource
registry or implicit transaction around delivery.

`titan.uv` stores the destination loop binding in its state-local module state.
Runtime initialization binds its initialized loop, and shutdown admission clears
that exact binding. Native reconstruction refuses an absent binding. UV hooks
own descriptor duplication/adoption and native pending-request checks; domain
adapters own buffered bytes, terminal state, and fresh local callbacks.

Buffered adapters use `snapshot_pending()` to copy their subscription queue and
terminal outcome before changing ownership. They consume the old queue only
after native detachment succeeds. This keeps queue storage inside async rather
than duplicating its bookkeeping in every adapter.
