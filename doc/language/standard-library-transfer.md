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

1. **Packet-scoped reference-counted resources**, registered in a native
   packet's resource table with `transfer.attach_resource` and claimed with
   `transfer.claim_resource`. In the standard library these are only
   [`thread.Sender<|T|>` and `thread.Receiver<|T|>`](standard-library-thread.md#closing-cloning-and-transferring-endpoints).
   Each encoded occurrence retains its own native reference in the packet and
   appears in the payload as a four-byte little-endian packet-local slot index.
   Decoding claims each slot into a destination wrapper whose finalizer is
   already registered. A reference is always held either by a live wrapper or
   by an undelivered packet: claiming moves it, and disposing of a packet
   releases the references it still holds. Disposal happens through
   `transfer.discard_message`, channel close or drain, failed or cancelled
   sends, abandoned thread results, and replaced or closed
   [`async.Receiver`](async-io.md#cross-state-receivers) slots, and runs in C
   without entering Lua, loading modules, invoking user decoders, or requiring
   an active Runtime. Closing an endpoint changes the channel's state but
   releases no reference.
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
Discarding an undelivered packet—whether through `transfer.discard_message`, a
full or closed `Sender:try_send`, a cancelled `Sender:send`,
`thread.Receiver:close()`, `async.Receiver` slot replacement or close, or an
abandoned `Thread` result—releases only resources registered in the packet's
native resource table. It never runs user or domain decoders as an incidental
cleanup mechanism. Sending an `http.Exchange`, `ssl.Connection`,
`net.Connection`, `websocket.Connection`, or other manual-handoff owner through
a thread channel or `async.Receiver` does not make its handoff transactional: a
failed send does not undo detachment, and discarding queued bytes does not close
the detached socket, TLS engine, HTTP exchange, WebSocket, descriptor, or
database handle. The caller must recover a rejected payload or explicitly
dispose of its resources, and must stop producers and drain/dispose unread
manual-handoff payloads before closing a receiver. Copying or dropping a byte
string does not duplicate or close the resources named by it.

An [`async.Receiver`](async-io.md#cross-state-receivers) is a lossy, coalescing
slot for native packets: `async.send` encodes with `transfer.encode_message`,
`Receiver:wait()` decodes with `transfer.decode_message`, and replaced or unread
packets are disposed of with `transfer.discard_message`. Like thread channels
and spawn, it can therefore carry endpoint attachments; `lua.Lua:run` and
`run_async` copy policies over a separate carrier without a resource table and
cannot. Standalone `TransferValue.from_value` and `protobuf.serialize` calls
open no packet scope, so converting an endpoint raises outside one. Inside an
enclosing packet scope the conversion reuses that packet, and the packet's
resource table, not the returned index bytes, owns the attachment. For
manual-handoff resources, keep ownership outside a lossy mailbox or use a
protocol that guarantees exactly-once adoption or explicit disposal. A
successful coalescing send alone proves neither, and sending the same
manual-handoff payload twice can cause double adoption.

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

`titan.transfer` encodes values into heap-allocated native packets, each with
its own resource table. Cross-thread channels, thread spawn and results, and
[cross-state receivers](async-io.md#cross-state-receivers) all carry these
packets:

```text
function encode_message(candidate: value): foreign *void
function decode_message(slot: foreign *(*void)): value
foreign function discard_message(raw: *void)
foreign function copy_message(raw: const *void): *void

function attach_resource(resource: foreign *void,
                         retain: foreign function (*void): void,
                         release: foreign function (*void): void): string
function claim_resource(index_bytes: string,
                        expected_release: foreign function (*void): void): foreign *void
function claim_registered_resource(
    context: value,
    data: foreign const *void,
    length: integer,
    expected_release: foreign function (*void): void): foreign *void
function register_resource(
    candidate: value,
    get: function (value): (foreign *void),
    retain: foreign function (*void): void,
    release: foreign function (*void): void,
    construct: function (value, foreign const *void, integer): (value))
```

### Raw packet encoding, decoding, copying, and disposal

`encode_message(candidate)` encodes any transferable Titan value or explicit
`TransferValue` into a new packet and returns its raw owner. Scalars, strings,
borrowed pointers, C functions, and explicit policies are copied into the packet
without a packet scope and never call a transfer hook. Records, unions, Titan
closures, and endpoints are encoded inside an encode scope for the new packet,
so their hooks, nested fields, and closure captures can attach resources to it
([below](#scoped-resource-attachments-and-packet-local-indexes)). Records
without hooks and unions are serialized straight into the packet, without an
intermediate `TransferValue` or Lua string. How packet storage grows is not part
of the contract; the
[implementation chapter](../implementation/transfer-library.md#flat-packets-and-direct-classification)
describes it.

`decode_message(slot)` is an ordinary public Titan function for trusted native
integrations. It reconstructs the value in the current Lua state and returns
it. Pass a **real caller-owned `foreign *void` local** that holds one uniquely
owned packet: passing a pointer local passes the address of that local itself
(see
[contextual object-pointer conversions](c-ffi-expressions.md#contextual-object-pointer-conversions)),
or pass an explicit `foreign *(*void)` slot address. A copied packet address
grants no ownership. Keep the slot and its enclosing owner alive throughout the
call. Lua code cannot call `decode_message`, because its raw C pointer
parameter has no dynamic Lua coercion.

Guard the local with `defer transfer.discard_message(raw)` as soon as it holds
the packet, and call `decode_message(raw)` **directly on that local**, in the
function that owns it, not through a forwarding helper: `decode_message` must
clear the guarded local itself.

```text
local raw = transfer.encode_message(v)
defer transfer.discard_message(raw)
return transfer.decode_message(raw)
```

When `decode_message` raises, the guard sees the slot it has already cleared
and does not dispose of the packet again. This holds however the local
received its packet, including by assignment inside an earlier protected
region such as a `do ... catch` block: a scalar local whose mutable address is
passed to a call and that recovery code reads is never restored from an older
copy, on Titan's supported toolchains
([C storage after a caught error](c-ffi-expressions.md#c-storage-after-a-caught-error)).

Once its body runs, `decode_message` consumes the packet and clears the slot on
every outcome, before it returns or an error propagates with its original
traceback: success, failure to reserve the result's stack slot
(`"transfer: cannot reserve packet operation stack"`), module initialization
failure, decoder or hook failure, partially claimed endpoints, and destination
setup failure. Only its own function entry can fail first, with a memory or
stack error; the slot then still owns the packet, and the caller's deferred
`discard_message` disposes of it.

A nil `slot` raises `"transfer: invalid packet owner slot"`, and an empty slot
raises `"transfer: cannot decode a NULL packet"`. Decoding leaves the caller's
Lua stack top unchanged. Decoding may enter Lua, load modules, allocate, and
run hooks. It is not part of the no-Lua discard chain, it does not synchronize
access to the state, and it does not create a Runtime. Ordinary code uses
`thread.channel`, `thread.spawn*`, or `async.send` / `Receiver:wait`, which
manage guarded packet locals themselves.

`discard_message(raw)` is a public C-ABI `foreign function` that releases any
unclaimed entries in the packet's resource table and frees the packet storage.
Passing `nil` is a no-op. Raw packet pointers are single-owner capabilities: if
a packet returned by `encode_message` or `copy_message` is not consumed by
`decode_message`, its raw owner must dispose of it once with
`transfer.discard_message`—**never** with `ffi.free`. Passing the same non-nil
allocation to a second consuming operation is invalid, even if every attachment
was already claimed. An emptied slot is not authority to reuse a saved address.

`copy_message(raw)` is a public C-ABI `foreign function` that duplicates a
packet without resource attachments. It returns `nil` if `raw` is `nil`, if the
packet has any resource-table entry, or if allocation fails; it never shares a
resource table between packets.

### Scoped resource attachments and packet-local indexes

While `encode_message` or `decode_message` encodes or decodes a record, union,
closure, or endpoint, it installs a packet scope for the current execution, the
Lua thread running the call. Scalar and policy packets need none. Scopes nest:
a nested `encode_message` or `decode_message` installs its own scope, then
restores the enclosing one on every normal or error exit, after disposing of
whatever its unfinished packet still owns.

- **Authority**: `attach_resource` succeeds only when the current execution's
  innermost scope is an encode scope, and `claim_resource` only when it is a
  decode scope. Otherwise they raise
  `"transfer: resource attachment requires an encode scope"` or
  `"transfer: resource claim requires a decode scope"`. Neither consults an
  enclosing scope or another Task's scope, and a separately resumed child
  `coroutine.Coroutine` does not inherit its caller's packet authority. Hooks
  remain synchronous and nonyielding; this isolation does not license a
  yielding hook.
- **Nested and standalone calls**: Custom hooks, nested protobuf messages, and
  closure capture snapshots that belong to a packet share its scope.
  `protobuf.serialize`, `protobuf.deserialize`,
  `protobuf.deserialize_nominal_buffer`, `TransferValue.from_value`, and
  `TransferValue:to_value` create no scope. Called from such hook or capture
  work, they use the enclosing packet; called anywhere else, endpoint fields and
  endpoint hooks raise. The index bytes and policies they produce own no
  attachments; the packet does. A packet operation active in another
  execution, including one in an abandoned coroutine, never lends authority. If
  an execution is abandoned mid-operation without unwinding, its unfinished
  packet and attachments are disposed of when the scope is collected; that
  safety net does not relax the hook rules.
- **Attachment (`attach_resource`)**: Rejects a `nil` `resource`, `retain`, or
  `release` (`"transfer: invalid native resource attachment"`), reserves room in
  the packet's resource table **before** calling `retain(resource)`
  (`"transfer: out of memory reserving resource attachment"`), records the
  resource with its `release` callback, and returns the entry's slot index as a
  four-byte little-endian string (`0` to `0xfffffffe`; `0xffffffff` is reserved
  as invalid). Each encoded occurrence of a resource adds its own entry and
  retain. `retain` and `release` must be C-only `foreign function (*void): void`
  callbacks that can run without a Lua state, module loader, or active Runtime.
  If encoding raises after one or more attachments, unwinding the scope
  releases every attachment of the unfinished packet.
- **Claim (`claim_resource`)**: Checks, in this order, that `index_bytes` is
  exactly four bytes (`"transfer: invalid resource attachment index width"`),
  that the index is not `0xffffffff` and lies within the packet's attachment
  count (`"transfer: resource attachment index is out of bounds"`), that
  `expected_release` is non-nil and equals the entry's recorded `release`
  callback (`"transfer: resource attachment kind mismatch"`, so a `Sender`
  decoder cannot claim a `Receiver` slot or vice versa), and that the entry has
  not been claimed (`"transfer: resource attachment was already claimed"`). It
  then marks the entry claimed and returns the resource pointer without
  allocating or yielding.
- **Finalizer-first adoption**: A `from_transfer_payload` hook must create its
  destination wrapper with an inert `nil` native pointer and register its GC
  finalizer **before** claiming, then store the returned pointer immediately,
  with no fallible call in between. If wrapper setup or the claim fails, the
  reference stays in the packet and is released when `decode_message` disposes
  of the packet; once the claim succeeds, the wrapper's finalizer owns it even
  if decoding a later field of the same packet raises.
- **Registered resources**: `register_resource(candidate, get, retain, release,
  construct)` and `claim_registered_resource` are compiled collaboration
  entries through which `titan.thread` registers its endpoint records, so that
  encoding and decoding need no hook call. `candidate` is any instance of the
  record; the registration covers every application of a generic record, and a
  non-record raises `"transfer: registered resource must be a record"`. In a
  packet, encoding such a record attaches `get(record)` with `retain` and
  `release` and writes its slot index directly. Decoding calls
  `construct(context, data, length)`, which must follow the finalizer-first
  order and claim with `claim_registered_resource(context, data, length,
  expected_release)`, passing on the `context` it received. That `context` is
  valid only until `construct` returns: do not store it or pass it to a later
  call. Using it afterwards is outside the contract and is not reliably
  detected; it can crash or claim from an unrelated packet. A `nil` context
  raises `"transfer: resource claim requires a decode scope"`; the other checks
  are those of `claim_resource`.
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
