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

Both hooks are synchronous and must not yield. A hook chooses its own byte
format. The generic policy stores the actual defining module, nominal name,
and bytes; native transports copy and free those strings. There is no generic
recursive payload graph or implicit native resource lifetime management.

[Protobuf field messages](standard-library-protobuf.md) let a hook encode and
decode an ordered list of typed fields without declaring a nominal payload
record. The same descriptor list serves both directions. This does not relax
protobuf's rejection of local nominal types or nominal types with private
members. The hook explicitly selects the private wrapper's transferable
fields. Raw pointers are encoded as fixed64 addresses and are valid only under
the same-process lifetime contract.

## Native resource handoff

Transfer hooks fall into two ownership categories:

1. **Packet-scoped reference-counted resources** registered in a native packet's
   resource table via `transfer.attach_resource` and claimed via
   `transfer.claim_resource`. In the standard library, this category initially
   comprises **only [`thread.Sender<|T|>` and `thread.Receiver<|T|>`](standard-library-thread.md#closing-cloning-and-transferring-endpoints)**.
   Each encoded occurrence retains an independent native reference in the active
   packet's resource table and writes a four-byte little-endian packet-local
   slot index into the payload. Decoding claims each slot into a pre-finalized
   destination wrapper, and native packet disposal (`transfer.discard_message`,
   `Packet:close()`, channel close/drain, failed or cancelled sends, abandoned
   thread results, or overwritten [`async.PacketReceiver`](async-io.md#owned-packet-receivers)
   slots) automatically releases any unclaimed entries in C without entering
   Lua, loading modules, invoking user decoders, or requiring an active Runtime.
2. **Manual-handoff resources**, including only the specific types in the
   [inventory below](#manual-handoff-api-inventory), and user hooks that do not
   register a C release callback via `attach_resource`. These hooks explicitly
   select copied state and native tokens. Moving an owned resource requires
   exactly-once detachment/adoption; a hook for a stable borrowed descriptor
   need not detach the source. Neither case adds a packet disposer.

Packet attachments use native reference counts, not a cycle collector. Queued
endpoints can form native channel cycles; retain a receiver and explicitly
close/drain it before dropping the last application handle. See
[endpoint lifetime rules](standard-library-thread.md#closing-cloning-and-transferring-endpoints).

**Native packet discard never decodes payloads or invokes `from_transfer_payload`.**
Discarding an undelivered packet—whether through `transfer.discard_message`,
`Packet:close()`, a full or closed `Sender:try_send`, a cancelled `Sender:send`,
`Receiver:close()`, `PacketReceiver` slot replacement or close, or an abandoned
`Thread` result—releases only resources registered in the packet's native
resource table. It never runs user or domain decoders as an incidental cleanup
mechanism. Sending an `http.Exchange`, `ssl.Connection`, `net.Connection`,
`websocket.Connection`, or other manual-handoff owner through a thread channel
or `PacketReceiver` does not make its handoff transactional: a failed send does
not undo detachment, and discarding queued bytes does not close the detached
socket, TLS engine, HTTP exchange, WebSocket, descriptor, or database handle.
The caller must recover a rejected payload or explicitly dispose of its
resources, and must stop producers and drain/dispose unread manual-handoff
payloads before closing a receiver. Copying or dropping a byte string does not
duplicate or close the resources named by it.

An [`async.Receiver`](async-io.md#cross-state-receivers) is a lossy, coalescing
notification mailbox for copied `TransferValue` policies. Policy conversion
does not create a packet scope: without a matching enclosing scope, endpoint
hooks raise. Nested opaque/capture conversion can reuse its enclosing packet's
scope, but the returned index bytes own nothing; that packet still owns the
attachments. Copying those bytes through `Receiver` does not transfer its
resource table or create standalone endpoint ownership. Slot replacement/close
only frees the copied storage. For coalescing endpoint ownership, use
[`async.PacketReceiver`](async-io.md#owned-packet-receivers) with
`transfer.Packet` and `async.send_packet`. For manual-handoff resources, keep
ownership outside a lossy mailbox or use a protocol that guarantees
exactly-once adoption or explicit disposal; a successful coalescing send alone
is not proof of either, and repeating the same manual-handoff payload may cause
double adoption.

Preflight rejection and failed native duplication preserve that endpoint's
source ownership. If io's second pipe duplication fails, its source retains
the first pipe's detached payload; later write/retry or close handles that
remaining ownership. Once a child hook has detached successfully, failure to
serialize the enclosing composite can make that source terminal: built-in
hooks explicitly dispose of the detached native resources before raising.
There is no whole-operation rollback or recoverable VM out-of-memory promise
for manual-handoff hooks.

UV TCP/pipe, `net.Connection`, `ssl.Connection`, `http.Exchange`,
`http.UpgradedStream`, and `websocket.Connection` provide type-specific
`discard_transfer_payload` operations for explicit release without reopening a
Runtime. Generic transfer dispatch recognizes only the `to_transfer_payload` and
`from_transfer_payload` hooks. Follow each resource chapter's disposal contract;
an adoption exception does not universally leave the entire original payload
retryable.

UV-backed destinations require an existing active async Runtime. Its loop is
bound for reconstruction when the Runtime initializes and unbound as shutdown
begins. Reconstruction never creates or drives a Runtime implicitly. Pending
native requests remain pending work after Task cancellation or `read_stop`.

Process lifetime handling stays in its original Runtime. Communication streams
can move independently; the original Process still owns exit notification,
waiting, and reaping. HTTP request and response endpoints move together as one
`http.Exchange` because they share parser and transport state.

Resource chapters document their supported states, buffers, and guards.

### Manual-handoff API inventory

Each type below provides `:to_transfer_payload(): string` and the corresponding
static `from_transfer_payload(payload: string)` returning that type. This is an
inventory of existing hooks, not a promise that every native-backed type in
these modules is transferable:

| Owning API | Supported handoff and recovery |
| --- | --- |
| [`uv.tcp_t`, `uv.pipe_t`](standard-library-uv.md#native-resource-handoff) | Eligible connected endpoints only, with the native pending-request and platform guards. Each has `discard_transfer_payload(payload): integer`. |
| [`net.Connection`](standard-library-net.md#transferring-connections), [`ssl.Connection`](standard-library-ssl.md#transferring-connections) | Idle connected transport plus buffered TCP/TLS state. Each has `discard_transfer_payload(payload): integer`. Listeners and arbitrary UV handles are not included. |
| [`http.Exchange`, `http.UpgradedStream`](standard-library-http.md#resource-handoff), [`websocket.Connection`](standard-library-websocket.md#transferring-connections) | The documented eligible exchange/session state plus its child transport. Each has `discard_transfer_payload(payload): integer`; individual HTTP request/response objects are not independent owners to move. |
| [`fs.File`](standard-library-fs.md#transferring-files) | Open idle descriptor plus retained read bytes; no pending operation. No public `discard_transfer_payload`: recover with `File.from_transfer_payload` and explicitly close the adopted File. Filesystem Watchers do not implement these hooks. |
| [`os.InputStream`, `os.OutputStream`](standard-library-os.md#transferring-process-streams) | Eligible captured pipes plus buffered/terminal state. Unused standard-stream facades preserve their stable process descriptor identity rather than moving it. No public `discard_transfer_payload`; use the documented adoption/close recovery. `os.Process` never moves. |
| [`io.InputOutputStream`](standard-library-io.md#transferring-shell-streams) | Eligible shell communication pipes only, not child-process ownership. No public `discard_transfer_payload`; recover through adoption/close. |
| [`sqlite3.Connection`](standard-library-sqlite3.md#transferring-connections) | Idle database handle with no open Statement or Cursor. No public `discard_transfer_payload`: recover with `Connection.from_transfer_payload` (or the retained policy's `to_value`) and close it. Statements and Cursors do not implement handoff. |

Adoption/close recovery retains each resource's usual Runtime and Task
requirements. Do not invent a generic discard hook for types that do not
export one, or abandon their payloads in a lossy transport.

### Shared manual-handoff rules

These rules apply to every type in the inventory above and to user hooks that do
not register a packet resource. Each resource chapter lists only its own
exceptions.

1. **Detach before delivery.** Encoding detaches the source. A source alias then
   behaves as closed or detached, and closing it cannot close the resource that
   the destination adopts. Chapters note the few exceptions, such as unused
   `os.stdin`, `os.stdout`, and `os.stderr` facades, which stay usable.
2. **One owner, one adoption.** A payload is a manually owned capability that is
   valid only in this process. It is not a persistence or cross-process format.
   Deliver and adopt it exactly once. Adopting or discarding it twice can close a
   resource twice or use freed memory, copying the bytes does not duplicate the
   resource, and dropping a payload leaks the detached resource. There is no
   replay protection, finalizer, or rollback of detachment.
3. **Recover failed delivery yourself.** If delivery fails, adopt the payload
   locally and close the result, or call the type's `discard_transfer_payload`
   where the inventory lists one. A `discard_transfer_payload` call needs no
   Runtime and returns the native close status. The close attempt consumes
   ownership even when that status reports an error, so never adopt or discard
   the same bytes afterward.
4. **Serialization failure after detachment.** If serializing the enclosing value
   fails after a hook has detached a resource, the built-in hooks close the
   detached resource themselves and leave the source closed or detached.
   `io.InputOutputStream` has one documented exception for a failed second pipe.
5. **Runtime and Task requirements.** The hooks are synchronous and do not need a
   running Task. Higher-level UV adapters (`net`, `ssl`, HTTP, WebSocket, and
   captured process/shell streams) require an active, non-closing Runtime for
   both hooks; raw `uv.tcp_t` and `uv.pipe_t` require an initialized owner loop
   on encode and an active, non-closing destination Runtime on decode (unused
   `os.stdin`, `os.stdout`, and `os.stderr` facades transfer descriptor identity
   without a pipe). Later operations on an adopted resource keep their usual
   Task requirements.

## Native message packets

`titan.transfer` owns heap-allocated native transfer packets
(`titan_async_message`), their single-owner `Packet` wrapper, and the
packet-scoped native resource table used by cross-thread channels and
[owned packet receivers](async-io.md#owned-packet-receivers):

```text
record Packet

function Packet.new(): Packet
function Packet.from_value(candidate: value): Packet
function Packet:borrow_owner(): foreign *void
function Packet:borrow_message(): foreign *void
function Packet:take_message(): foreign *void
function Packet:decode(): value
function Packet:close()

function encode_message(candidate: value): foreign *void
foreign function decode_message(state: *lua_State, slot: *(*void)): int
foreign function adopt_into(raw_owner: *void, slot: *(*void)): int
foreign function discard_message(raw: *void)
foreign function copy_message(raw: const *void): *void
function raise_message_error(status: integer, failure: value)

function attach_resource(resource: foreign *void,
                         retain: foreign function (*void): void,
                         release: foreign function (*void): void): string
function claim_resource(index_bytes: string,
                        expected_release: foreign function (*void): void): foreign *void
```

### `Packet` ownership and move semantics

`Packet` is an opaque single-owner handle for one native packet allocation.
There is no `clone` method; copying a `Packet` variable in Titan aliases the
same wrapper and its consumed/closed state.

- `Packet.new()` constructs an inert, finalized owner containing no message.
- `Packet.from_value(candidate)` prepares that owner first, then encodes
  `candidate` and stores the resulting packet in its native cell.
- `Packet:borrow_message()` returns the underlying non-nil raw packet pointer
  without consuming ownership, or raises
  `"transfer: packet is consumed or closed"` if decoded, taken, or closed.
  **The pointer is neither an owner nor a GC root.** Keep the Packet rooted for
  the entire borrow. The borrow ends when any alias closes, decodes, takes, or
  successfully publishes the packet; the pointer is invalid for the borrower
  after that ownership transition. Never pass it to consuming operations
  (`discard_message`, `decode_message`, or `adopt_into`) while the
  wrapper still owns it.
- `Packet:take_message()` detaches and returns the non-nil raw allocation,
  leaving every alias of the Packet consumed. The caller becomes its unique
  owner and must give it to exactly one consuming operation or discard it once.
  Call `take_message` **before** handing raw ownership to another consumer;
  borrowing is not a substitute. Calling `borrow_message`, `take_message`, or
  `decode` on an already consumed or closed Packet raises
  `"transfer: packet is consumed or closed"`. These ordinary checked methods
  are not generic allocation-free native handoff primitives.
- `Packet:decode()` consumes the packet and reconstructs the value in the
  current Lua state.
- `Packet:close()` is idempotent: it detaches any remaining raw packet pointer
  and disposes it with `discard_message`. GC finalization uses the same native
  take/discard path as a nonyielding fallback for an unconsumed Packet.

`Packet:borrow_owner()` is an internal-purpose compiled collaboration entry for
native transports. It borrows the Packet's stable native owner cell, including
when empty; it does not root the Packet or transfer the message. Keep the Packet
reachable until every use of that cell has ended. Ordinary checked preparation
must finish before native take/publication, which then writes/clears the
prepared owner directly. Neither the owner cell nor its current message may be
freed by the borrower.

`adopt_into(raw_owner, slot)` is a pure C-ABI move into an already-finalized
Packet. Prepare/root an **empty** `Packet.new()` and obtain `borrow_owner()`
before acquiring a raw packet; if a raw packet already exists, keep its actual
local slot under a native discard guard throughout that allocating preparation.
Then directly call `adopt_into` at that guarded slot:

- `0` stores the unique raw allocation in the destination and clears the source
  slot in one native interval.
- `-2` rejects a nil owner/slot address, `-4` an occupied destination, and `-5`
  a nil source allocation. Every rejection leaves both owners unchanged.
- It does not enter Lua, allocate, yield, throw, create a wrapper, or dispose a
  previous destination value. A non-nil borrowed owner must still name valid
  rooted Packet storage; these checks cannot validate arbitrary addresses.
- Handle errors only after the native return has committed the source slot
  update. `raise_message_error(status, nil)` translates a rejection if desired;
  the source guard remains responsible for any unadopted allocation.

### Raw packet encoding, decoding, copying, and disposal

`encode_message(candidate)` accepts any transferable Titan value or an explicit
`TransferValue`. Scalars (`nil`, `boolean`, `integer`, `float`, binary `string`,
lightuserdata pointers, Lua threads as borrowed `*lua_State`, unbranded Lua
userdata as borrowed payload pointers, and bare Lua C functions or zero-upvalue
C closures) are classified directly from their Lua tags without constructing a
`reflect.Value` wrapper. Branded Titan closures are validated directly against
their module manifest and projected without hydrating reflection function
signatures, while public records and unions are inspected once at the root and
serialized directly into an expandable native buffer prefixed with the message
header (`titan_async_message`), without creating an intermediate `TransferValue`
or Lua string for the root message.

`decode_message(state, slot)` is a public source-defined C-ABI entry for trusted
Lua/native integrations. It returns a native status rather than the decoded
value. Pass an exclusively owned, live Lua state and the address of a **real
caller-owned `void *` slot** that holds one uniquely owned packet. A copied
borrowed packet address grants no ownership. Keep the slot and its enclosing
owner alive throughout the call.

Call it **directly on the actual guarded local slot** and keep the returned
status. Do not route the slot through an ordinary forwarding wrapper, and do not
propagate an error out of the native boundary after the slot changed. A normal
return commits Titan's mutable-address spill back to the local before any
ordinary helper can raise.

With a valid slot, `decode_message` reconstructs the semantic value in `state`
and clears and consumes the packet on every outcome, including stack
reservation failure, module initialization failure, ordinary worker-entry
failure, and destination setup failure. Disposal of any residual owner finishes
before the status returns, and the entry does not rethrow after mutating the
slot. The status means:

- `0`: exactly one decoded value, possibly nil, sits above the Lua stack top
  saved at entry.
- A positive Lua status: exactly one rooted error sits above that saved top.
  Only after the direct native return and slot commit may ordinary code
  propagate it.
- `-2`: the slot address is nil. No stack value is added.
- `-3`: stack reservation failed. No stack value is added, and a valid slot is
  still cleared and disposed.

An empty input slot produces a positive error status for
`"transfer: cannot decode a NULL packet"`.

At the original call site, copy the result or error into traced Titan storage
before entering any ordinary helper, because a helper's own preamble can change
the stack top. For a nonnegative status copy the top value; for a negative
status use nil instead of reading the stack. Save and restore the exact Lua
stack top around the call. For a nonzero status, then call
`raise_message_error(status, failure)` to propagate the original error and
traceback (positive status) or the matching setup diagnostic (negative status).
That helper is not a raw-owner boundary and must not run before the slot's
native return has committed. Do not call it on success.

Protected decode may enter Lua, load modules, allocate, and run hooks. It is
not the no-Lua discard chain, it does not synchronize access to the state, and
it does not create a Runtime. Ordinary callers should use `Packet.from_value`
and `Packet:decode`.

`discard_message(raw)` is a public C-ABI `foreign function` that releases any
unclaimed entries in the packet's resource table and frees the packet storage.
Passing `nil` is a no-op. Raw packet pointers are single-owner capabilities:
if a packet returned by `encode_message`, `copy_message`, or
`Packet:take_message()` is neither decoded nor successfully moved into a
prepared Packet by `adopt_into`, its raw owner must dispose of it once with
`transfer.discard_message`—**never** with `ffi.free`. Passing the same non-nil
allocation to a second consuming operation is invalid, even if every attachment
was already claimed. An emptied slot is not authority to reuse a saved address.

`copy_message(raw)` is a public C-ABI `foreign function` that duplicates only
attachment-free packets (`resources.entries == nil`, `count == 0`, and
`capacity == 0`). It returns `nil` if `raw` is `nil`, if the packet owns any
resource-table entries or capacity, or if heap allocation fails; it never
shallow-copies a resource table.

### Scoped resource attachments and packet-local indexes

`encode_message` and `decode_message` maintain a direction-specific scope stack
for each actual Lua thread within the state:

- **Execution-local exact top authority**: `attach_resource` is permitted only
  when the current execution's exact top frame is an encode scope (otherwise
  raising `"transfer: resource attachment requires an encode scope"`).
  `claim_resource` requires that same execution's exact top frame to be a
  decode scope (otherwise raising
  `"transfer: resource claim requires a decode scope"`). Neither operation
  searches an older enclosing frame or another Task's scope for permission.
  A separately resumed child `coroutine.Coroutine` does not inherit its
  caller's packet authority. Hooks remain synchronous and nonyielding; this
  isolation does not authorize yielding hooks.
- **Nested and standalone calls**: Opaque custom hooks, nested protobuf
  messages, and closure capture snapshots belonging to the same packet share its
  top scope. A nested `encode_message` or `decode_message` call pushes its own
  scope frame and restores the exact enclosing scope on every normal or error
  exit. `protobuf.serialize`, `TransferValue.from_value`, and
  `TransferValue:to_value` do not create scopes. When invoked as opaque-hook or
  capture work inside a matching current scope, they reuse that enclosing
  packet; without it endpoint hooks raise. Their temporary index bytes/policies
  own no attachments and are not standalone reusable ownership.
  Scope ownership also has a nonyielding finalizer guard: if an execution stack
  is abandoned without lexical unwind, its unfinished native table/packet is
  still disposed. That safety mechanism does not broaden the hook contract.
- **Attachment (`attach_resource`)**: Rejects a `nil` `resource`, `retain`, or
  `release` argument (`"transfer: invalid native resource attachment"`),
  reserves capacity in the encode scope's resource table **before** calling
  `retain(resource)` (`"transfer: out of memory reserving resource attachment"`),
  records `(resource, release, claimed = 0)`, and returns a four-byte
  little-endian unsigned slot index string (`0..0xfffffffe`; `0xffffffff` is
  reserved as invalid). Each encoded occurrence of a resource adds a separate
  retain and table entry. Both `retain` and `release` must be C-only
  `foreign function (*void): void` callbacks that can run without a Lua state,
  module loader, or active Runtime. If encoding raises after one or more
  attachments, unwinding the encode scope automatically releases all entries in
  the uncommitted table.
- **Claim and adoption (`claim_resource`)**: Validates that `index_bytes` is
  exactly four bytes (`"transfer: invalid resource attachment index width"`),
  decodes the four-byte little-endian unsigned slot index, checks that the index
  is not `0xffffffff` and lies within the current packet's attachment count
  (`"transfer: resource attachment index is out of bounds"`), checks that
  `expected_release` is non-nil and matches the entry's recorded `release`
  callback (`"transfer: resource attachment kind mismatch"`, preventing a
  `Sender` decoder from claiming a `Receiver` slot or vice versa), and checks
  that the slot has not already been claimed
  (`"transfer: resource attachment was already claimed"`). It then marks the
  slot claimed and returns the native pointer without allocating or yielding.
- **Finalizer-first adoption**: A resource's `from_transfer_payload` hook must
  allocate its destination wrapper with an inert `nil` native pointer and
  register its GC finalizer **before** calling `claim_resource`, then assign the
  returned pointer immediately. If wrapper setup or `claim_resource` fails, the
  retain remains in the packet table and is released when `decode_message`
  disposes the packet; once `claim_resource` succeeds, the wrapper owns the
  retain through its normal finalizer even if decoding a later field in the
  same packet raises.
- **Packet-local index guarantee**: The four-byte slot index is meaningful only
  against the active packet's resource table; it is **not** a global
  anti-replay token across different packets (where slot `0` may name a valid
  attachment of that other packet). The safety guarantee is that payload bytes
  never carry raw native pointers or callback addresses, cannot cross resource
  kinds, and cannot claim any slot of the current packet more than once.

## Raw module loader

The public foreign function below supports trusted integrations with the Lua C
API, including `titan.lua` and `titan.thread`. It is available through an
ordinary compiled import of `titan.transfer`:

```text
foreign function transfer_load_module(state: *lua_State,
                                      name: const *char,
                                      length: unsigned long long)
```

Call it only inside a protected entry for the exclusively owned `state`, with
`name` valid for `length` bytes throughout the call. The public compiled
signature uses contextual `unsigned long long` for `length` and raises
`"transfer module name exceeds native size"` if `length` exceeds `SIZE_MAX`. It
reserves three temporary stack slots, calls that exact name's preload function
with zero arguments, and leaves one canonical module above the entry stack top.
The generated initializer memoizes module state. The result must equal the
generated module's existing registry entry before any native manifest is read.
An owning-state Lua preload wrapper is valid if it returns that canonical
module.

Loading may allocate or raise into the owning protected boundary. The caller
keeps the returned module rooted and restores its stack after use. This raw
function supplies no independent-state synchronization or error protection.

This is an explicitly stateful operation, unlike the C-only resource
retain/release/discard chain. A `foreign function` declaration alone does not
mean its body is safe without a live Lua state.
