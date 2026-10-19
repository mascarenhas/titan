# Transfer policy implementation

`titan/transfer.titan` owns `TransferValue`, single-owner `Packet` wrappers,
native packet encoding/decoding/adoption/copying/disposal (`encode_message`,
`decode_message`, `adopt_into`, `copy_message`, `discard_message`), packet-scoped resource
attachment/claim (`attach_resource`, `claim_resource`), `transfer_load_module`,
custom-record hook selection, immediate closure capture conversion, and
destination reconstruction. Its common native packet and resource-table header
(`titan/transfer_native.h`) is separated from the receiver slot header
(`titan/async_receiver_native.h`). `titan.transfer` imports `reflect`,
`protobuf`, and `gc`, without depending on `uv`, `async`, or `thread`. `async`
exports a transparent alias of `TransferValue`.

## Flat packets and direct classification

Nominal and custom-record packets carry the actual defining module, qualified
nominal name, and opaque bytes. A closure packet carries its defining module,
immutable entry token, and opaque snapshot bytes. The legacy native `Receiver`
and `titan.lua` worker boundaries copy scalar fields and strings; they do not
walk capture graphs, retain Lua objects, or attach packet-scoped resources.

`TransferValue.from_value` and `encode_message` share direct classification
paths before falling back to general reflection:
1. **Direct scalar Lua tags (`scalar_message_kind`)**: Inspects the raw `TValue`
   tag directly without constructing a `reflect.Value` wrapper. It handles
   `LUA_TNIL`, `LUA_TBOOLEAN`, `LUA_TNUMBER` (testing `LUA_VNUMINT` to keep
   integers distinct from integral floats and `-0.0`), `LUA_TSTRING` (preserving
   exact byte length), `LUA_TLIGHTUSERDATA`, `LUA_TTHREAD` (borrowed
   `*lua_State`), unbranded or unknown-brand `LUA_TUSERDATA` (borrowed payload
   pointer via `lmacro_getudatamem`, while rejecting known Titan brands
   `TITAN_ARRAY..TITAN_OWNED` from the scalar path so records and unions take
   their nominal path and unsupported Titan brands raise), and `LUA_TFUNCTION`
   for light C functions and zero-upvalue C closures (rejecting `NULL` C
   functions and non-Titan C closures with upvalues).
2. **Demand-driven Titan closure classification**: When `LUA_TFUNCTION` is a C
   closure with `nupvalues >= 5` and `upvalue[3] == TITAN_BRAND`,
   `scalar_message_kind` returns a negative kind and transfer dispatches directly
   to `snapshot_closure` or `snapshot_closure_to_buffer` (`project_closure_captures`).
   `transfer_closure_entry` validates the closure header, brand, module
   userdata, and manifest entry (`entry.native` and `entry.strict`) directly in
   C without calling `reflect.inspect`. Consequently, neither root nor nested
   closure transfer hydrates reflection's `FunctionType` signature text, while
   explicit `reflect.inspect` calls preserve eager full `FunctionValue` /
   `FunctionType` descriptors without needing a signature cache.
   Scalar packets are allocated and initialized directly by
   `new_scalar_message`; they no longer stage an automatic message header or
   call `copy_message`. Explicit nominal byte carriers still stage a header.
3. **Registered nominal resource capability (`protobuf.find_resource_codec`)**:
   In `encode_packet`, before scalar or reflection dispatch, a `LUA_TUSERDATA`
   candidate is checked against `protobuf.find_resource_codec(candidate)` by its
   canonical erased metatable (`TITAN_BRAND == TITAN_RECORD`). On a hit
   (`thread.Sender` or `thread.Receiver`), `encode_packet` resolves the
   declaring module (`nominal_module`) and `codec.descriptor.name`, computes the
   complete packet size `sizeof(titan_async_message) + 4 + #name + #module`, and
   reserves that capacity in one heap-backed `owned *titan_protobuf_buffer`
   **before** calling `codec.encode(scope, candidate)`. It then sets
   `buf.length = sizeof(titan_async_message)`, writes the four-byte
   little-endian slot index via `protobuf.write_resource_index`, and calls
   `finalize_buf_message` to append `name` and `module` and fill the packet
   header in the same allocation prefix—producing the
   `TITAN_ASYNC_MESSAGE_RECORD_PAYLOAD` packet in one heap allocation with no
   Lua index string, no reflective hook invocation, and no staged `copy_message`.
4. **Single structural root inspection and carried packet context**: When a
   non-scalar, non-function value is inspected once with
   `reflect.inspect(candidate)` and yields `is_record(record_value)` (with no
   custom transfer hooks) or `is_union(union_value)`, transfer passes that
   already-inspected descriptor and the packet's `ResourceScope` (`scope`)
   directly to `protobuf.serialize_inspected_record_to_buffer` or
   `protobuf.serialize_inspected_union_to_buffer`. Because `titan.transfer` and
   `titan.protobuf` are separate compiled modules that do not use private
   `.titan` source imports across module boundaries, these helpers are ordinary
   compiled functions on `titan.protobuf` with an internal role: they avoid a
   second `reflect.inspect` at the root and carry `scope` once for all nested
   fields while preserving all visibility, active-record cycle, nesting-depth
   (128), and 2 GiB message-size checks. Public `protobuf.serialize` and
   `protobuf.serialize_to_buffer` remain unchanged.

Custom hook signatures are exactly `to_transfer_payload(): string` and
`from_transfer_payload(payload: string): Record`; both remain synchronous and
nonyielding. Reflected signature checks precede invocation
(`protobuf.find_transfer_hooks`). Resolve the source record's
actual module (`nominal_module`) before invoking an encoder, since the encoder
can detach native resources. Do not infer that module by splitting a qualified
name.

Nominal reconstruction queries the registry first (`reflect.find_nominal`). Only
a miss invokes the recorded module's preload loader via `transfer_load_module`,
then retries nominal lookup. Module initialization remains memoized. No raw
initializer capability or source module userdata crosses states.

`encode_message` and `decode_message` provide direct native packet
(`titan_async_message`) serialization for `titan.thread`, `transfer.Packet`, and
`async.PacketReceiver` without requiring source imports across modules. For
records, unions, and closures, `encode_message` initializes an
`owned *titan_protobuf_buffer` on the C heap, reserves
`sizeof(titan_async_message)` at the front, serializes the wire payload in place
via `protobuf.serialize_inspected_record_to_buffer`,
`protobuf.serialize_inspected_union_to_buffer`, or
`protobuf.serialize_fields_to_buffer`, appends the nominal/module name bytes,
and detaches the single allocation with `titan_protobuf_buf_take_data`.
Decode reads directly from the packet's byte slices using
`protobuf.deserialize_nominal_buffer_with_context` (passing `scope` once for
`RECORD` and `UNION` packets) and `protobuf.deserialize_fields_buffer` under the
current execution's decode scope. For a `RECORD_PAYLOAD` packet, after
`initialize_nominal_raw` ensures the destination module is loaded in the
receiving state, `decode_message_worker` checks
`protobuf.find_resource_codec_by_name(name)`: registered resource types invoke
`codec.decode(scope, message.bytes, message.length)` directly on the borrowed
packet slice without allocating a four-byte payload string or running a
reflected hook, while other custom-hook records copy the payload string and
dispatch `from_transfer_payload`. The native scope owner disposes the packet and
unclaimed attachments after reconstruction or an error; already claimed endpoint
wrappers retain their own finalized ownership.

### Protected raw-owner entry and prepared handoff

These source-defined foreign entries have portable signatures and are available
through ordinary compiled imports:

```text
foreign function decode_message(state: *lua_State, slot: *(*void)): int
foreign function adopt_into(raw_owner: *void, slot: *(*void)): int
```

**Protected decode.** `decode_message` receives a live exclusively owned Lua
state and actual caller-owned `void *` slot storage. Its foreign body checks the
slot and reserves three Lua stack slots. Nil, boolean, integer, float, borrowed
pointer/state and valid bare C-function packets then decode in C without a
scope, worker lookup or protected call. The native path consumes and clears the
actual slot and disposes the packet. Strings and nominal reconstruction retain
the protected worker path: an error handler and zero-upvalue dispatch thunk enter
`lua_pcallk` before any ordinary decoder worker entry can allocate. Stack
reservation failure clears/discards the input and returns `-3`. Protected
dispatch clears/discards any remaining raw owner and retains one result/error.
Scalars and explicit `TransferValue` policies are classified and copied before
encode scope creation; structural and hook work still creates an exact scope.

`decode_message_worker` prepares an execution-local ResourceScope, registers its
finalizer, installs lexical exact-top restoration/native disposal, and inserts
the scope before `move_slot_to_scope` moves and clears the caller's slot into
the scope's native cell. Ordinary worker-entry failure, module initialization,
and scope-preparation failure therefore leave the input owned by the native
boundary; after commit the scope owns it.

Protected dispatch looks up its traced, state-local worker closure with
`lua_rawgetp` under `decode_message_dispatch`'s native code address. A cold miss
loads transfer inside that same protected boundary and retries. Only the key is
a native address; the registry value retains the closure and declaring module
through collection, without a per-packet string-key lookup.

| Decode status | Caller slot | Provided Lua stack |
| --- | --- | --- |
| `0` | nil | saved top plus one semantic value, including nil |
| Positive Lua status | nil; residual packet disposed | saved top plus one error |
| `-2`, nil slot address | no valid slot | unchanged |
| `-3`, stack reservation failure | nil; packet disposed | unchanged |

The direct call must occur at the actual guarded local slot. It returns normally
even on decoder failure: a nonlocal exit after mutation would skip the caller's
generated mutable-address spill commit. At that original callsite, copy the
stack result/error into traced `value` storage for nonnegative status, or use
nil for negative status, **before entering an ordinary helper** whose preamble
could change the top. Thread passes only status and that explicit value to its
semantic helper; no raw slot is forwarded through an ordinary wrapper.
The caller owns exact Lua-stack save/restore on every exit.

Only after native return may the error branch call the public ordinary
`raise_message_error(status: integer, failure: value)`. It raises the explicit
positive-status failure with its original trace, or a negative-status setup
diagnostic, without accepting any raw owner. `Packet:decode()` handles this
internally: ordinary preparation runs while the Packet still owns its
allocation, then a pure native helper takes its inline owner and calls the
protected decoder with no intervening ordinary entry. Error translation happens
only after native return and aliases already observe the cleared source.

Decode enters Lua, may initialize transfer and destination modules, and may run
decoders; it cannot use a closed state and is not part of the no-Lua release
chain. Raw `discard_message` still needs neither a state nor a Runtime.

**Prepared native adoption.** `Packet.new()` creates/finalizes an inert owner;
`Packet:borrow_owner()` borrows its inline cell without rooting it. Prepare and
root that empty owner before raw acquisition, or retain an existing raw-slot
discard guard throughout all allocating preparation. Then call `adopt_into`
directly at the actual guarded source slot. It is a pure native move: no Lua,
allocation, throwing, yielding, wrapper creation, or previous-value disposal.
Status `0` writes the allocation into the prepared empty cell and clears the
source. Status `-2` rejects a nil owner/slot address, `-4` an occupied destination,
and `-5` a nil source, leaving both owners unchanged. Non-nil addresses remain
trusted borrows, not validated arbitrary pointers. Rejection may be translated
with `raise_message_error(status, nil)` only after the native return; the
original source guard still owns any unadmitted allocation.

### Native module loading

`transfer_load_module` is a public source-defined foreign function shared with
`titan.lua` and `titan.thread` through an ordinary compiled import. Its exact
portable signature is
`(state: *lua_State, name: const *char, length: unsigned long long)` with no C
return value. It checks `length <= SIZE_MAX` before converting to `size_t` and
borrows `length` valid bytes for the call. Inside the exclusively owned state's
protected entry, the helper reserves three stack slots and calls the preload
function with zero arguments and one result. It then checks that result against
the existing `"Titan module " .. name` registry entry populated by the generated
initializer. Only that canonical module remains above the saved entry top on
success. Preload wrappers cannot substitute unrelated native userdata before
manifest lookup. Allocation and Lua errors reach the enclosing protected entry;
callers own the module root and subsequent stack cleanup.

This loader is stateful Lua-stack/registry work, not part of the no-Lua
retain/release/discard chain. Provider code pointers used by that native chain
remain valid after a state closes under the existing
[stable native-image binding and process-lifetime DSO mapping](foreign-functions.md#source-collaboration-and-binary-isolation)
rule; that does not make a closed `lua_State` usable by `transfer_load_module`.

## Closure snapshots

`project_closure_captures` converts a closure's captures for both `from_value`
and `encode_message`. Source-defined foreign helpers (`transfer_closure_entry`
and `transfer_project`) validate its source entry and project **all immediate
semantic captures onto the Lua stack before any custom hook runs**. That stack
range roots and freezes the complete immediate capture frontier while Titan
converts each capture once in declaration order via `TransferValue.from_value`,
so a custom hook in an earlier capture cannot mutate a shared captured box
before a later capture is read. A nested closure or custom record is already
opaque bytes when inserted into its parent's snapshot.

One anonymous protobuf message has two array fields: `{TransferValue}` policies
and `{boolean}` flags recording which captures were already policy wrappers.
The shared ordered `reflect.Type` descriptors serve serialization and
deserialization. No public snapshot record, parallel private nominal metadata,
or separate tagged binary codec is needed.

On reconstruction, load the destination owner and resolve the token by pointer
equality against its entry manifest before dereferencing it or decoding any
captured resource. Validate both array lengths against the manifest count and
every policy slot before invoking any `to_value` decoder. Read flags as dynamic
values and require every slot to be a boolean: Array holes are legal independently
of their element descriptors, and a boolean conversion could turn nil into false.

Each reconstructed closure receives fresh mutable cells. Aliases between
related source closures are intentionally not preserved. Module globals refer
to destination state. The active-record and active-closure Maps detect only
reentrant conversion cycles and unwind with `defer`; there are no graph
identity indexes, mutable-cell registries, or graph allocation ledgers.

## Scoped resource table and manual resource ownership

### Packet-scoped resource table (`titan_transfer_resource_table`)

`titan/transfer_native.h` embeds `titan_transfer_resource_table resources`
(`entries`, `count`, `capacity`) in `titan_async_message`. Each entry
(`titan_transfer_resource`) holds `(void *resource, titan_transfer_resource_fn
release, int claimed)` and contains only native pointers and C-ABI callbacks—no
Lua/Titan GC objects or state-bound closures.

The standard ownership rules are:

- **Each unit is owned by exactly one of: a live finalized wrapper, or an
  unconsumed message entry.** Wrapper-only reference counting is insufficient:
  when a worker creates a channel pair and returns it through `Thread:join()`,
  the worker's `lua_close` finalizes both worker wrappers before the parent
  reconstructs the result, so only the unconsumed result packet's entries keep
  the channel alive until parent adoption. Likewise, if the sole source `Sender`
  wrapper is collected while its encoded packet is still queued, the unconsumed
  packet entry prevents premature EOF.
- **Adoption moves a unit; discard releases it; close changes state only.**
- **Message bytes, wake targets, loop liveness, and OS-thread retirement are
  separate lifetimes.** Wrapper counting simplifies none of them.

The scope, registration, attachment, claim, and disposal mechanics are:

- **Execution-local, direction-specific scope stacks (`ResourceScope`)**:
  `resource_scopes` maps the actual current Lua thread value, obtained by
  `current_execution()` with `lua_pushthread`, to that execution's linked top.
  It is an ephemeron Map, not a raw-address registry: a suspended execution can
  keep its scope alive, while an unreachable execution/scope cycle is
  collectible. Each frame stores `execution`, `previous`, direction, a
  `titan_transfer_scope_owner` native cell containing its unfinished resource
  table/owned decode packet, and a borrowed message pointer for claim lookup.
  `encode_message` pushes an encode frame; decode pushes a distinct decode
  frame after preparing its owner. Lexical deferred cleanup restores exactly
  `resource_scopes[execution] = previous` and calls the pure foreign
  `dispose_scope` on the frame's native cell on normal or error exit. Only the
  current execution's exact top authorizes attachment or claim; no older matching
  phase is searched. Same-stack protobuf fields, opaque hooks, and closure
  capture conversion share the top, but nested packet operations push their
  own frame. Other Tasks and separately resumed child Coroutines inherit no
  packet authority. `gc.finalizable(scope, finalize_resource_scope)` supplies a
  nonyielding fallback for an abandoned execution stack that never runs its
  lexical defer; the finalizer invokes that same native disposal path for
  unfinished retains/owned packet. This isolation/abandonment mechanism does not make
  yielding transfer hooks supported. Standalone protobuf/policy conversion
  opens no scope and cannot manufacture ownerless endpoint references.
- **Transfer-mediated nominal capability registration (`register_resource` and
  `claim_registered_resource`)**: During module initialization, `titan.transfer`
  installs `packet_context` into `protobuf.set_packet_context_provider`, and
  `titan.thread` calls `transfer.register_resource` with inert `Sender<|value|>`
  and `Receiver<|value|>` instances, typed native-pointer accessors, C-ABI
  retain/release functions, and finalizer-first constructors. `register_resource`
  inspects the record once and registers a `protobuf.ResourceCodec` keyed on the
  record's canonical erased metatable identity. All components—the metatable
  identity, `RecordType` descriptor, and fixed `encode`/`decode` closures
  retaining `titan.thread` and `titan.transfer`—stay traced in state-local
  module variables, and private userdata field offsets never cross module
  boundaries. The carried `context` passed to `codec.encode` and
  `claim_registered_resource` is only ever a live `ResourceScope` from the
  current packet call (never serialized or cached); a `nil` context raises the
  standard missing-scope error. Public `attach_resource` and `claim_resource`
  continue to resolve `resource_scopes[current_execution()]` on every call for
  opaque user hooks and `TransferValue` policy conversions.
- **Capacity-before-retain attachment (`ResourceScope:attach` and
  `attach_resource`)**: After checking the encode scope and non-nil `resource`,
  `retain`, and `release` pointers, `reserve_resource` grows the table inside
  `scope.native` (up to `TITAN_TRANSFER_INVALID_INDEX = 0xffffffff`, so valid
  slot indexes are `0..0xfffffffe`) **before** `attach_reserved` calls
  `retain(resource)`. Once `retain` returns, the entry
  `{ resource, release, claimed = 0 }` is written and `count` incremented
  immediately. Both `attach_resource` and `protobuf.write_resource_index` format
  the four-byte little-endian index through
  `protobuf.write_resource_index_bytes`. If writing or pushing the index or
  subsequent encoding raises, native scope disposal releases the unfinished
  table. On successful packet creation `commit_resources` transfers that table
  into `raw->resources` and zeroes the source table in one native interval,
  independent of earlier buffer growth/detachment.
- **Validated claim and finalizer-first adoption (`ResourceScope:claim`,
  `claim_resource`, and `claim_registered_resource`)**: Checks the decode scope,
  requires `length == 4`, decodes the four-byte little-endian unsigned slot
  index (inverse of `protobuf.write_resource_index_bytes`), checks
  `index ~= 0xffffffff` and `index < scope.message.resources.count`, checks
  `expected_release ~= nil and entry.release == expected_release`, and checks
  `entry.claimed == 0`. It then sets `entry.claimed = 1`, clears
  `entry.resource = nil`, and returns `resource` with no subsequent allocation
  or yield. Both the registered constructors (`sender_from_resource` /
  `receiver_from_resource`) and the hook decoders
  (`Sender.from_transfer_payload` / `Receiver.from_transfer_payload`) allocate a
  fresh wrapper with `native = nil` and register `gc.finalizable` **before**
  claiming, then assign `native` immediately with no fallible ordinary entry in
  between. Thus a failure before or during the claim leaves the retain owned by
  the packet table, while a failure in a later field after the claim leaves the
  claimed wrapper owned by the destination GC and disposes only the remaining
  unclaimed packet entries.
- **Reentrant C-only disposal (`dispose_resources`, `discard_message`) and
  `copy_message`**: `dispose_resources` detaches `entries`, `count`, and
  `capacity` from the table header before iterating over `0..count - 1` and
  calling `release(resource)` on entries with `claimed == 0`, then frees
  `entries`. Detaching first ensures recursive release paths (such as releasing
  the last `thread.Receiver`, which drains its channel and discards nested
  packets) cannot observe the table as still owned. Public foreign
  `discard_message(raw)` is NULL-safe, calls `dispose_resources` on
  `&message->resources`, and frees `message` without entering Lua, loading
  modules, running user decoders, or requiring a Runtime. Public foreign
  `copy_message(raw)` refuses any packet with non-zero `resources` (`entries`,
  `count`, or `capacity`), copying only attachment-free packets.
- **Prepared `Packet` owner**: `Packet.new()` creates an inert, finalized
  wrapper containing one inline `titan_transfer_packet_owner` cell.
  `Packet:borrow_owner()` borrows that stable cell while the Packet is rooted;
  it neither transfers ownership nor retains the wrapper. Native publication
  and take helpers operate on prepared cells, so a source is cleared before
  any post-publication disposal/notification, and receive takes directly into
  a finalized destination. These native commits must not be replaced with an
  ordinary take/adoption call after native ownership moved:
  even an ordinary function with a field-only body has generated entry/stack/GC
  work before its first lexical guard. Wrapper aliases share the same cell and
  consumed state. `borrow_message` is a nonowning/nonrooting interval; callers
  must take ownership before using raw consuming APIs.

The resource table adds no native cycle collection. Queued receiver attachments
can keep their own channel, or a cycle of channels, alive after all Lua wrappers
are unreachable. The application must explicitly close/drain a reachable
receiver to break that graph; see the
[native endpoint lifetime rules](thread-library.md#endpoint-transfer-c-abi-release-chain-and-last-receiver-pin).

### Manual resource handoff

Only resources registered in the packet table via `attach_resource` (initially
`thread.Sender` and `thread.Receiver`) are automatically released by
`discard_message`. The
[manual-handoff API inventory](../language/standard-library-transfer.md#manual-handoff-api-inventory)
names the exact supported UV TCP/pipe, network/TLS/HTTP/WebSocket, File,
process-stream, shell-stream, and SQLite Connection hooks. Watchers, Processes,
SQLite Statements/Cursors, and arbitrary native-backed owners are not implied.
These hooks select buffered bytes, scalar state, native address fields, and
child hook bytes, usually through protobuf's anonymous field API. Only UV owns
libuv duplication/adoption and pending-request checks; domain adapters own
semantic state and fresh destination callbacks. The transport copies bytes
without following native pointers, and `discard_message` never invokes
`from_transfer_payload`.

Legacy `async.Receiver` delivery is lossy: native notifications coalesce and
callbacks replace unread `TransferValue` policies. Overwriting or discarding a
packet in `Receiver` or `PacketReceiver` releases only transport storage and
any packet-table entries registered via `attach_resource`, without invoking
manual resource disposal hooks. A successful send therefore does not establish
exactly-once delivery or adoption for manual-handoff resources, including native
tokens hidden inside closure snapshots; the application must retain an ownership
protocol outside the lossy packet.

Preflight and duplication failures retain endpoint ownership. io preserves its
first detached pipe when a second duplication fails. Other post-detach encoding
failures can terminalize the composite after explicit disposal. This is not a
generic transaction around hooks or delivery; successful manual-handoff payloads
remain manually owned and must be adopted exactly once or explicitly disposed
through an API that actually exists for that type. UV TCP/pipe and the
network/TLS/HTTP/WebSocket owners export `discard_transfer_payload`; File,
process/shell streams, and SQLite Connection instead require their documented
adoption/close recovery.

UV stores the destination loop binding in state-local module state. Runtime
initialization binds its initialized loop, and shutdown admission clears that
exact binding. Native reconstruction refuses an absent binding. Buffered
adapters use `snapshot_pending()` before changing ownership and consume the old
queue only after native detachment succeeds.

See [Receiver ownership](libuv-runtime.md#cross-state-receiver-ownership),
[Lua state loading](lua-library.md), and the individual resource chapters.
