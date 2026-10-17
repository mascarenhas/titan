# Transfer policy implementation

`titan/transfer.titan` owns `TransferValue`, custom-record hook selection,
immediate closure capture conversion, and destination reconstruction.
It imports reflection and protobuf without UV or async. `async` exports a
transparent alias of the same policy type.

## Flat packets

Nominal and custom-record packets carry the actual defining module, qualified
nominal name, and opaque bytes. A closure packet carries its defining module,
immutable entry token, and opaque snapshot bytes. The native Receiver and Lua
worker boundaries copy scalar fields and strings; they do not walk capture
graphs, retain Lua objects, or manage native resource ownership.

Custom hook signatures are exactly `to_transfer_payload(): string` and
`from_transfer_payload(payload: string): Record`. Reflected signature checks
precede invocation. Resolve the source record's actual module before invoking
an encoder, since the encoder can detach native resources. Do not infer that
module by splitting a qualified name.

Nominal reconstruction queries the registry first. Only a miss invokes the
recorded module's preload loader, using an ordinary protected Lua call,
then retries nominal lookup. Module initialization remains memoized. No raw
initializer capability or source module userdata crosses states.

`encode_message` and `decode_message` provide direct native packet
(`titan_async_message`) serialization for `titan.thread` without requiring
source imports across modules. For records, unions, and closures,
`encode_message` initializes an `owned *titan_protobuf_buffer` on the C heap,
reserves `sizeof(titan_async_message)` at the front, serializes the wire payload
in place via `protobuf.serialize_to_buffer` or `protobuf.serialize_fields_to_buffer`,
appends the nominal/module name bytes, and detaches the single allocation with
`titan_protobuf_buf_take_data`. `decode_message` reads directly from the packet's
byte slices using `protobuf.deserialize_nominal_buffer` and
`protobuf.deserialize_fields_buffer` and frees the packet via `defer ffi.free`.

`transfer_load_module` is a public source-defined foreign function shared with
`titan.lua` through an ordinary compiled import. Its exact raw signature is
`(state: *lua_State, name: const *char, length: size_t)` with no C return value.
The name borrows `length` valid bytes for the call. Inside the exclusively owned
state's protected entry, the helper reserves three stack slots and calls the
preload function with zero arguments and one result. It then checks that result
against the existing `"Titan module " .. name` registry entry populated by the
generated initializer. Only that canonical module remains above the saved entry
top on success. Preload wrappers cannot substitute unrelated native userdata
before manifest lookup. Allocation and Lua errors reach the enclosing protected
entry; callers own the module root and subsequent stack cleanup.

## Closure snapshots

`from_value` converts a closure immediately. Source-defined foreign helpers validate its
source entry and project all immediate semantic captures onto the Lua stack
before any custom hook runs. That stack range roots the complete set while
Titan converts each capture to its selected policy. A nested closure or custom
record is already opaque bytes when inserted into its parent's snapshot.

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

## Resource ownership

Resource hooks explicitly select buffered bytes, scalar state, native address
fields, and child hook bytes, usually through protobuf's anonymous field API.
Only UV owns libuv duplication/adoption and pending-request checks; domain
adapters own semantic state and fresh destination callbacks. The transport
copies bytes without following native pointers.

Receiver delivery is lossy: native notifications coalesce and callbacks replace unread
values. Packet replacement frees only transport storage, without invoking
resource disposal hooks. A successful send therefore does not establish
exactly-once delivery or adoption. This applies equally to native tokens hidden
inside closure snapshots; the application must retain an ownership protocol
outside the lossy packet.

Preflight and duplication failures retain endpoint ownership. io preserves its
first detached pipe when a second duplication fails. Other post-detach encoding
failures can terminalize the composite after explicit disposal. This is not a
generic transaction around hooks or delivery; successful native handoff payloads
remain manually owned and must be adopted exactly once or explicitly disposed.

UV stores the destination loop binding in state-local module state. Runtime
initialization binds its initialized loop, and shutdown admission clears that
exact binding. Native reconstruction refuses an absent binding. Buffered
adapters use `snapshot_pending()` before changing ownership and consume the old
queue only after native detachment succeeds.

See [Receiver ownership](libuv-runtime.md#cross-state-receiver-ownership),
[Lua state loading](lua-library.md), and the individual resource chapters.
