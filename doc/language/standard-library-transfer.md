# Transfer policies

`import "transfer"` names `titan.transfer`, the independent-state value policy
module. `transfer.TransferValue` is the canonical union;
`async.TransferValue` is a transparent alias of the same type.

See [transfer values](async-io.md#transfer-values) for the complete union,
`from_value`, `to_value`, closure snapshots, and custom record hooks.
This module does not create an async Runtime or deliver messages.

## Opaque payloads

Custom hooks have the exact signatures:

```text
function Record:to_transfer_payload(): string
function Record.from_transfer_payload(payload: string): Record
```

A hook chooses its own synchronous byte format. The generic policy stores the
actual defining module, nominal name, and bytes; native transports copy and free
those strings. There is no generic recursive payload graph or implicit native
resource lifetime management.

[Protobuf field messages](standard-library-protobuf.md) let a hook encode and
decode an ordered list of typed fields without declaring a nominal payload
record. The same descriptor list serves both directions. This does not relax
protobuf's rejection of local nominal types or nominal types with private
members. The hook explicitly selects the private wrapper's transferable
fields. Raw pointers are encoded as fixed64 addresses and are valid only under
the same-process lifetime contract.

## Native resource handoff

Standard-library resource hooks perform a manual, exactly-once handoff. The
origin checks pending work and snapshots buffered semantic state. A successful
hook detaches the origin owner before returning its payload. The destination
adopts that payload into fresh local wrappers. A failed send does not undo
detachment: the caller must recover the returned payload or explicitly dispose
of its resources. Copying or dropping a byte string does not duplicate or
close the resources named by it.

A Receiver is a [lossy, coalescing notification](async-io.md#cross-state-receivers):
a successful send may be overwritten before receipt. Replacing or discarding
that packet releases its bytes but does not dispose of native resources inside
it, including resources in captured closure payloads. Keep ownership outside
the lossy message or use a separate handoff protocol that guarantees exactly-once
adoption or disposal. Successful `send` alone is not proof of either. Repeating
the same payload may also cause double adoption; lack of an acknowledgement
alone does not authorize disposing of a resource the destination may own.

Preflight rejection and failed native duplication preserve that endpoint's
source ownership. If io's second pipe duplication fails, its source retains
the first pipe's detached payload; later write/retry or close handles that
remaining ownership. Once a child hook has detached successfully, failure to
serialize the enclosing composite can make that source terminal: built-in
hooks explicitly dispose of the detached native resources before raising.
There is no whole-operation rollback or recoverable VM out-of-memory promise.

UV TCP/pipe, net.Connection, ssl.Connection, and http.UpgradedStream provide
type-specific `discard_transfer_payload` operations for explicit release
without reopening a Runtime. Generic transfer dispatch recognizes only the
to/from hooks. Follow each resource chapter's disposal contract; an adoption
exception does not universally leave the entire original payload retryable.

UV-backed destinations require an existing active async Runtime. Its loop is
bound for reconstruction when the Runtime initializes and unbound as shutdown
begins. Reconstruction never creates or drives a Runtime implicitly. Pending
native requests remain pending work after Task cancellation or `read_stop`.

Process lifetime handling stays in its original Runtime. Communication streams
can move independently; the original Process still owns exit notification,
waiting, and reaping. HTTP request and response endpoints move together as one
`http.Exchange` because they share parser and transport state.

Resource chapters document their supported states, buffers, and guards.

## Raw module loader

The public foreign function below supports trusted integrations with the Lua C
API, including `titan.lua`. It is available through an ordinary compiled import
of `titan.transfer`:

```text
foreign function transfer_load_module(state: *lua_State,
                                      name: const *char, length: size_t)
```

Call it only inside a protected entry for the exclusively owned `state`, with
`name` valid for `length` bytes throughout the call. It reserves three temporary
stack slots, calls that exact name's preload function with zero arguments, and
leaves one canonical module above the entry stack top. The generated initializer
memoizes module state. The result must equal the generated module's existing
registry entry before any native manifest is read. An owning-state Lua preload
wrapper is valid if it returns that canonical module.

Loading may allocate or raise into the owning protected boundary. The caller
keeps the returned module rooted and restores its stack after use. This raw
function supplies no independent-state synchronization or error protection.
