# Transfer policy implementation

`titan/transfer.titan` owns `TransferValue`, native packet encoding, decoding,
copying and disposal (`encode_message`, `decode_message`, `copy_message`,
`discard_message`), packet-scoped resource attachment and claim
(`attach_resource`, `claim_resource`, `register_resource`),
`transfer_load_module`, custom-record hook selection, closure capture conversion,
and destination reconstruction. The packet and resource-table layouts are in
`titan/transfer_native.h`; the `async.Receiver` slot header
(`titan/async/async_receiver_native.h`) is separate. `titan.transfer` imports
`reflect`, `protobuf` and `gc`, and does not depend on `uv`, `async` or
`thread`. `async.TransferValue` is a transparent alias.

The packet consumers are `titan.thread` (channel items, spawn closures,
outcomes and cancellation reasons; see
[thread packets](thread-library.md#native-message-packets-and-nested-custom-transfer-hooks))
and the coalescing `async.Receiver`
([receiver ownership](libuv-runtime.md#cross-state-receiver-ownership)). The
`titan.lua` worker boundary uses `TransferValue` policies over its own carrier:
it copies scalars and strings, never walks capture graphs or retains Lua
objects, and has no packet resource table ([Lua state loading](lua-library.md)).

## Flat packets and direct classification

A packet is one heap allocation: a `titan_async_message` header, the payload
bytes, the `name`/`module` strings, and, when resources are attached, an aligned
tail of `titan_transfer_resource` entries. Nominal and custom-record packets
carry the declaring module, the qualified nominal name and opaque bytes. A
closure packet carries its defining module, the immutable entry token and the
snapshot bytes.

`encode_message` classifies its candidate in this order. Only the last row
acquires a `ResourceScope`; the first two leave any enclosing scope intact.

| Order | Test | Packet path |
| --- | --- | --- |
| 1 | `candidate is TransferValue` | `transfer_policy_to_message`: `new_scalar_message`, or `new_nominal_message(..., nil)` for `is_record`/`is_union`/`is_closure`/`is_record_payload` |
| 2 | `scalar_message_kind(candidate) >= 0` | `scalar_value_to_message` → `new_scalar_message` |
| 3 | otherwise | acquire a scope, then `encode_packet(candidate, scope)` |

`encode_packet` then tries, in order:

1. **Registered resource root.** A `LUA_TUSERDATA` whose metatable has no
   metatable and that `protobuf.find_resource_codec` matches by canonical
   erased metatable (`thread.Sender`, `thread.Receiver`). As in
   `TransferValue.from_value`, a metatable with its own metatable skips this
   lookup, so an inherited `__index` runs once, for the reflective brand
   lookup only. The complete one-entry packet size is
   reserved before `codec.encode(scope, candidate)` attaches the endpoint; the
   four-byte index is written with `protobuf.write_resource_index` and
   `finalize_buf_message` produces a `RECORD_PAYLOAD` packet in place.
2. **Titan closure.** `project_closure_captures` runs once, before
   `init_packet_buffer`, so captures and hooks execute once and the module
   length is known before reservation; see [closure snapshots](#closure-snapshots).
3. **Generated nominal codec.** `protobuf.find_generated_codec(candidate)` writes
   through `protobuf.serialize_generated_to_buffer` with the packet's scope as
   context. Endpoint fields attach through the reflective resource branch;
   hooked, Array and foreign fields use one reflective `Encoder` created on the
   first such field, so attachment order and errors match the reflective root
   ([generated nominal codecs](protobuf-library.md#generated-nominal-codecs)).
4. **One `reflect.inspect`.** `is_lua_userdata` becomes a `POINTER` scalar
   packet. A record with transfer hooks (`protobuf.find_transfer_hooks`) becomes
   a `RECORD_PAYLOAD` packet through `new_nominal_message(..., scope.native)`,
   which commits the scope's attachments. Other records and unions pass the
   inspected descriptor and `scope` to
   `protobuf.serialize_inspected_record_to_buffer` /
   `serialize_inspected_union_to_buffer`, avoiding a second root inspection.
   Anything else raises `"transfer: unsupported value"`.

`scalar_message_kind` reads the raw `TValue` tag before any scope or execution
lookup:

- `nil`, booleans, integers (`LUA_VNUMINT`, kept distinct from integral floats
  and `-0.0`), floats, strings (exact byte length), light userdata and threads
  (borrowed `*lua_State`) are scalars.
- Full userdata is a borrowed `POINTER` when it has no metatable, or when its
  metatable has no metatable and its brand is outside `TITAN_ARRAY..TITAN_OWNED`. A metatable
  with its own metatable returns `-1`, deferring any `__index` triggered by a
  brand lookup until the scope exists.
- Light C functions and zero-upvalue C closures are `FUNCTION` scalars; a NULL C
  function raises. A C closure with `nupvalues >= 5` and `TITAN_BRAND` in
  `upvalue[3]` is a Titan closure and returns `-1`; any other C closure with
  upvalues raises.

`new_scalar_message` and `new_nominal_message` check every length against
`SIZE_MAX`, allocate the final packet once and write the header directly; they
never stage an automatic header or go through `copy_message`. Structural
packets use `init_packet_buffer` and `finalize_buf_message`:

- `init_packet_buffer` reserves the header plus at most 64 bytes of metadata
  credit in a heap `titan_protobuf_buffer` and leaves the header prefix
  uninitialized. Serializers only append at `buf.length`, and
  `titan_protobuf_buf_free_heap` never reads the header.
- `finalize_buf_message` reserves the exact trailer (`packet_storage_size`),
  zeroes and fills the header, copies `name`/`module`, commits the scope's
  attachments into the tail, and detaches with `titan_protobuf_buf_take_data`.
  A detached packet is never reallocated.

Buffer growth, including how the metadata credit interacts with the bulk-write
slack, is canonical in [protobuf encoding](protobuf-library.md#encoding).

Custom hooks are exactly `to_transfer_payload(): string` and
`from_transfer_payload(payload: string): Record`, checked by reflected signature
in `protobuf.find_transfer_hooks` before invocation; both are synchronous and
must not yield. Resolve the record's declaring module (`nominal_module`, from
`TITAN_MT_MOD`) before invoking an encoder, because the encoder can detach
native resources. Never derive the module by splitting a qualified name.

`TransferValue.from_value` shares `scalar_message_kind` and opens no scope. For
userdata whose metatable has no metatable it checks
`protobuf.find_resource_codec` before reflective hook lookup and passes
`packet_context(true)`. `TransferValue:to_value` resolves the capability with
`protobuf.find_resource_codec_by_name` and passes `packet_context(false)`. Both
keep the four-byte index inside `is_record_payload`. Without an enclosing packet
scope, `packet_context` is nil and endpoint hooks raise.

Nominal reconstruction (`initialize_nominal_raw`) queries `reflect.find_nominal`
first. Only a miss calls `transfer_load_module` for the recorded module and
retries. No initializer capability or module userdata crosses states. The
module initializer installs `initialize_nominal` with
`protobuf.set_nominal_loader`, so a nominal held in a `value` or erased generic
field anywhere in a packet loads its declaring module on demand during packet
decode. `TransferValue:to_value` outside a packet initializes only its root
nominal's module; a nominal named only inside a `value` field must already be
registered in the destination state.

### Consuming raw-slot decode

```text
function decode_message(slot: foreign *(*void)): value
```

`decode_message` is an ordinary compiled function that decodes into the calling
state and consumes the packet in `slot[0]`. Its generated preamble
(`luaC_checkGC`, `titan_ensure_stack`) runs before the body reads `slot`; an
error there leaves the packet in `slot[0]` for the caller's guard. The body:

1. raises `"transfer: invalid packet owner slot"` for a nil `slot`;
2. for a scalar that Titan boxes directly (`NIL`, `BOOLEAN`, `INTEGER`,
   `FLOAT`, `STATE`, `POINTER`), boxes the value, clears the slot, discards the
   packet and returns. This path uses no Lua stack slot, allocation, protected
   region or scope, so it has no failure of its own;
3. otherwise calls `decode_message_worker(slot)` inside one inline `catch`. The
   catch clears `slot[0]`, discards any residual owner and re-raises with a bare
   `raise`, preserving the original error and traceback
   ([trace pinning](error-handling.md#trace-pinning)).

`decode_message_worker` copies `STRING` bytes, and makes a `FUNCTION` packet's
light C function (`cfunction_to_value`, the one value that needs
`lua_pushcclosure`), while the slot still owns the packet, and then discards
it. A `FUNCTION` packet with a NULL pointer, or a Lua stack that cannot take
that one slot, raises with the packet still in the slot. Neither acquires a
scope. `RECORD`, `UNION`,
`CLOSURE` and `RECORD_PAYLOAD` packets acquire a scope, install its retiring
`defer`, and only then call `move_slot_to_scope`, so every earlier failure
(worker entry, scope preparation) leaves the packet in the caller's slot for the
catch. `RECORD`/`UNION` decode through
`protobuf.deserialize_nominal_buffer_with_context` with the scope and the
`reflect.NominalType?` from `initialize_nominal_raw`; `CLOSURE` through
`restore_closure_from_buffer`. A `RECORD_PAYLOAD` whose name has a registered
resource codec calls `codec.decode(scope, bytes, length)` on the borrowed packet
slice; other hooked records copy the payload and call `from_transfer_payload`.
Scope retirement then disposes the packet and any unclaimed attachments; claimed
endpoint wrappers keep their own finalized ownership.

| Outcome | Caller slot | Lua stack |
| --- | --- | --- |
| value returned | nil; packet disposed | unchanged |
| error raised by the body | nil; residual packet disposed before propagation | restored by the catching boundary |
| error raised by decode's own entry preamble | unchanged; the caller's guard disposes | restored by the catching boundary |
| nil slot address | no valid slot | unchanged |

Caller recipe: give a real `foreign *void` local its packet in its own
declaration, install `defer discard_message(raw)` (or the domain's discard
wrapper) immediately, and call `decode_message(raw)` directly in that function.
A forwarding helper would add its own fallible entry preamble before decode
takes ownership, and a captured local cannot supply mutable pointer storage. The
pointer local reaches the `foreign *(*void)` parameter through
[contextual object-pointer conversion](c-ffi-expressions.md#contextual-object-pointer-conversion);
because a deferred guard reads it, codegen gives it a volatile home plus a
declaration-time escape barrier, so a stale spill cannot restore an owner that
decode already cleared. `decode_message` itself contains a `setjmp` and is not
inlined by supported GCC/Clang, including with LTO. The guarantee and its ISO C
caveat are in
[recovery storage](error-handling.md#setjmp-sensitive-localparameter-spills).

Callers are `thread.Receiver` receive paths, child bootstrap, cancellation
delivery, terminal-status reconstruction and `async.Receiver:wait` (which
declares a fresh local per loop turn and installs its guard only after
`receiver_take_native` reports a packet). Lua cannot call `decode_message`:
generated Lua entries have no coercion for raw C pointer parameters.

Decode enters Lua, may initialize modules and runs decoders, so it needs a live
state. `discard_message` needs neither a state nor a Runtime.

### Native module loading

`transfer_load_module(state: *lua_State, name: const *char, length: unsigned long long)`
is a public source-defined foreign function shared with `titan.lua` and
`titan.thread`. It checks `length <= SIZE_MAX`, borrows the name bytes for the
call, reserves three stack slots, calls the `LUA_PRELOAD_TABLE` loader with zero
arguments and one result, and requires that result to be the
`"Titan module " .. name` registry entry, so a preload wrapper cannot substitute
other userdata before manifest lookup. On success only the canonical module
remains above the entry top. It must run inside the target state's protected
entry; Lua and allocation errors propagate there, and the caller owns the module
root and later stack cleanup.

This is stateful Lua work, not part of the no-Lua release chain, and it cannot
use a closed state. Provider code pointers that the native release chain calls
stay mapped after a state closes under the
[process-lifetime provider binding](foreign-functions.md#source-collaboration-and-binary-isolation).

## Closure snapshots

This section owns closure-transfer policy. The generated manifest, projection
and restore functions are in
[cross-state closure transfer metadata](codegen-overview.md#cross-state-closure-transfer-metadata).

**Eligibility.** Every first-class source function, lambda, bound method and
realized callable adapter has a manifest entry, so a referenced local function
transfers like an exported one. Captured nominals follow the public protobuf or
custom-hook policy; local nominal types are ineligible. Unsupported
reconstruction conversions fail during projection, before the packet exists.

**Projection.** `project_closure_captures` serves both `from_value` and
`encode_packet`. `transfer_closure_entry` is an ordinary function: it reads
the closure's header, brand and module userdata from a `foreign TValue` copy
with the `lmacro_*` bridges, matches `entry.native`/`entry.strict` against the
module's manifest (all without `reflect.inspect`), and returns the manifest
entry and the module's name as values. The source-defined foreign helper
`transfer_project` then calls the generated callback, which pushes **all**
immediate captures onto the Lua stack before any hook runs. That rooted range
freezes the capture frontier while Titan converts each capture once, in
declaration order, with `TransferValue.from_value`, so a hook in an earlier
capture cannot mutate a shared box before a later capture is read. A nested
closure or custom record is already opaque bytes inside its parent. Neither
root nor nested closure transfer hydrates reflection's `FunctionType` signature
text.

**Roots.** Validation holds only C pointers: into the closure, into its module
userdata and into that module's immutable manifest. The closure is the
caller's argument, which the caller keeps reachable
([calls](values-and-gc.md#calls-c-only-inputs-immediate-result-roots-and-vm-transport)),
and it holds its module in its first upvalue; the manifest is static data of
the module's image. The module name is copied into a Titan string that the
calling frame roots. The Lua stack is used only where the generated callbacks'
ABI requires it: the projected captures, and on reconstruction the loaded
module and the captures to restore. `nominal_module` reads a nominal's
declaring module name through `titan_codec_nominal_module`
(`titan-runtime/transfer.h`), without the stack.

**Snapshot format.** One anonymous protobuf message (`closure_fields`) has two
Array fields: the `{TransferValue}` policies and `{boolean}` flags marking
captures that were already `TransferValue` policies, which reconstruction keeps
as unions instead of unwrapping. A captured record goes through its hook or
protobuf policy and carries its declaring module from `TITAN_MT_MOD`.

**Reconstruction** (`restore_closure_from_buffer`):

1. Load the packet's module through `transfer_load_module`. No initializer
   pointer travels with the packet.
2. Resolve the token by pointer equality against that provider's manifest
   entries (`transfer_resolve`, an ordinary function over the module userdata
   that `transfer_module_value` validated in its stack slot) before
   dereferencing it. An invalid token or a different physical provider is
   rejected before any capture is decoded.
3. Check both array lengths against the entry's capture count and every policy
   slot before any `to_value` decoder runs. Read each flag through a typed
   `boolean` local: Array holes are legal regardless of the element descriptor,
   and a truthiness conversion would turn nil into false.
4. Push each policy (flagged slots as the union itself, others through
   `to_value()`) and call the generated restore function through the foreign
   helper `transfer_restore`, which checks the capture range on the stack.

Each reconstructed closure gets fresh mutable cells; aliasing between related
source closures is not preserved. Module globals refer to the destination
state. `transfer_active_closures` and protobuf's active-record Map detect only
reentrant conversion cycles and unwind with `defer`; there are no identity
indexes or cell registries.

**Lifetime.** Titan's loader and its package searcher keep provider images mapped
for the process lifetime, so a transferred closure stays valid after its source
state closes. Manually loaded native libraries keep the caller-owned code
lifetime, as for raw C functions and preload snapshots. A packet pins no origin
Lua object.

## Scoped resource table and manual resource ownership

### Packet-scoped resource table (`titan_transfer_resource_table`)

`titan_async_message.resources` is `{entries, count}` with no capacity. Each
`titan_transfer_resource` is `{void *resource; titan_transfer_resource_fn release;}`
and holds only a native pointer and a C-ABI callback, never a GC object or
state-bound closure. A NULL `resource` marks a consumed entry; `release` stays,
so a later wrong-kind claim still reports a kind mismatch before the duplicate
claim. Committed entries live in the packet's aligned tail; `entries` is NULL
when `count == 0`. Changing `titan_async_message` or
`titan_transfer_resource_table` changes the packet contract shared by every
provider: rebuild every provider, consumer and native fixture cleanly; there is
no mixed-layout shim.

Ownership rules:

- **Each endpoint reference unit is owned by exactly one of a live finalized
  wrapper or an unconsumed packet entry.** Wrapper-only counting is
  insufficient: a worker that returns a new channel pair through
  `Thread:join()` finalizes both wrappers in its `lua_close` before the parent
  decodes the result, so only the packet entries keep the channel alive until
  adoption. Likewise a queued packet keeps a channel open after its sole source
  `Sender` wrapper is collected.
- **Adoption moves a unit; discard releases it; close changes state only.**
- **Message bytes, wake targets, loop liveness and OS-thread retirement are
  separate lifetimes.**

The table adds no cycle collection: queued receiver attachments can keep their
own channel, or a cycle of channels, alive after every wrapper is unreachable.
The application must close a reachable receiver to break it
([last-receiver pin](thread-library.md#endpoint-transfer-c-abi-release-chain-and-last-receiver-pin)).

#### `ResourceScope` frames and exact-top authority

`ResourceScope` holds `encoding` (direction), `native` (an inline
`titan_transfer_scope_owner` cell: scratch `resources`, `capacity`, owned decode
`message`, and `inline_entries[TITAN_TRANSFER_INLINE_RESOURCES]`, 96 bytes on
LP64), a borrowed `message` mirror for claim lookup, and `free_next`. The
current execution key and the enclosing `previous` frame stay in the lexical
locals of `encode_message` and `decode_message_worker`, so a frame never
references its execution or parent.

- **Authority.** `resource_scopes` is an ephemeron Map from the current Lua
  thread value (`current_execution`, via `lua_pushthread`) to that execution's
  top frame. Only that exact top authorizes attach or claim, in the matching
  direction; no older frame is searched. Protobuf fields, opaque hooks and
  capture conversion on the same stack share the top; nested packet work pushes
  its own frame. Other Tasks and separately resumed child coroutines inherit
  nothing. Standalone protobuf and policy conversion open no scope and cannot
  manufacture endpoint references.
- **Fast negative.** `current_resource_scope` returns nil without resolving the
  execution when the state-wide `active_scope_count` is zero. Each entry point
  increments the count before registering its retiring `defer`, so the count
  can only over-estimate (an abandoned stack never decrements it). A positive
  count grants nothing.
- **Acquisition.** `acquire_resource_scope` pops the state-local idle stack, or
  allocates an inert frame and registers `finalize_resource_scope` with
  `gc.finalizable` before the frame gains authority or native ownership.
- **Retirement** is an inline `defer` (no fallible ordinary call after packet
  commit), in this order: restore `resource_scopes[execution] = previous` and
  decrement the count; `dispose_scope(scope.native)`, which detaches everything
  before releasing uncommitted units, frees a heap spill, discards an owned
  decode packet and zeroes the cell; clear `message` and `encoding`; push the
  frame on the idle stack only while fewer than `idle_resource_scope_limit`
  (8) frames are idle. Overflow frames are left to GC; their zeroed cell makes
  the finalizer a no-op.
- **Abandonment.** A suspended stack that never runs its `defer` never returns
  its frame to the pool; `finalize_resource_scope` releases its scratch units,
  heap spill and owned packet natively. This does not make yielding hooks
  supported.

Generated `defer`/`catch` recovery reaches retirement under sustained
`LUA_ERRMEM` without interning strings ([error recovery](error-handling.md)).

#### Registration, attachment and claim

- **Registration.** At initialization `titan.transfer` installs `packet_context`
  with `protobuf.set_packet_context_provider`, and `titan.thread` calls
  `register_resource` with inert `Sender<|value|>`/`Receiver<|value|>`
  instances, native-pointer accessors, C-ABI retain/release callbacks and
  finalizer-first constructors. `register_resource` inspects the record once and
  calls `protobuf.register_resource_codec`, keyed by canonical erased metatable
  identity. Everything stays in traced state-local module variables; private
  field offsets never cross modules. The `context` passed to `codec.encode` and
  `claim_registered_resource` is the current packet's `ResourceScope` frame
  itself; nil raises the missing-scope error. Public `attach_resource` and
  `claim_resource` resolve the top through `current_resource_scope` on every
  call.
- **Attachment** (`ResourceScope:attach`). After checking the encode scope and
  non-nil `resource`, `retain` and `release`, `reserve_resource` reserves a slot
  **before** `attach_reserved` calls `retain`. The first four entries use
  `inline_entries`; the fifth moves them to an 8-entry `malloc` array (the
  inline address is never passed to `realloc`); later growth doubles with
  `realloc`, capped at `TITAN_TRANSFER_INVALID_INDEX` (`0xffffffff`, so valid
  indexes are `0..0xfffffffe`) and checked against `SIZE_MAX`. A failed spill
  leaves every prior unit owned by the scope for native rollback.
- **Commit.** Every packet path reserves header, payload, metadata, padding and
  the exact tail before detaching or allocating. `packet_storage_size` adds the
  aligned tail only when `count > 0` and returns 0 on overflow;
  `commit_resources` copies the scratch entries into the tail and zeroes the
  scope's count. Root endpoints pre-reserve a one-entry packet; opaque hook roots
  commit through `new_nominal_message(..., scope.native)`; scalar and policy
  packets carry an empty table.
- **Claim** (`ResourceScope:claim`, via `claim_resource` or
  `claim_registered_resource`), in this order: decode-scope check (`message`
  non-nil); `length == 4`;
  little-endian index `~= 0xffffffff` and `< count` (`"transfer: resource
  attachment index is out of bounds"`); `entry.release == expected_release`
  (`"transfer: resource attachment kind mismatch"`); `entry.resource ~= nil`
  (`"transfer: resource attachment was already claimed"`). It then clears
  `entry.resource` and returns the pointer with no further allocation or yield.
  Constructors allocate the inert wrapper (`native = nil`) and register
  `gc.finalizable` **before** claiming, then assign `native`. A failure before or
  during the claim leaves the unit in the packet; a failure in a later field
  leaves claimed wrappers to the destination GC and releases only the remaining
  entries. Indexes are packet-local, not global anti-replay tokens.
- **Retained contexts.** Only a live decode frame has a `message`: encode
  frames never set it and retirement clears it. A context kept past its decode
  therefore raises `"transfer: resource claim requires a decode scope"` while
  its frame is idle or serves an encode. Reuse by a later decode is not
  detected. The context *is* the pooled frame, so a holder reads the frame's
  current state and carries no older generation to compare; detecting reuse
  would need a distinct handle per decode, an allocation on every decode. The
  stale context then claims from the new packet. The kind check keeps that
  memory-safe, but the claim takes a slot the new packet's own constructor
  expects.

#### C-only disposal and copy

`dispose_resources` detaches `entries` and `count` before
`dispose_resource_entries` releases each non-NULL entry, so a recursive release
(for example the last `thread.Receiver` draining nested packets) never sees the
table as still owned. `discard_message` then frees the single packet allocation.
It enters no Lua, loads no module, runs no decoder and needs no Runtime.
`copy_message` returns NULL for any packet with attachments; only
attachment-free packets can be copied.

### Manual resource handoff

Only packet-table resources registered through `attach_resource` (today
`thread.Sender` and `thread.Receiver`) are released by `discard_message`. The
[manual-handoff API inventory](../language/standard-library-transfer.md#manual-handoff-api-inventory)
lists the supported UV TCP/pipe, net/TLS/HTTP/WebSocket, File, process-stream,
shell-stream and SQLite Connection hooks; Watchers, Processes, SQLite
Statements/Cursors and other native-backed owners are not covered. Their
hooks encode buffered bytes, scalar state, native identifiers and child hook
bytes, usually through protobuf's anonymous field API. The transport copies
those bytes without following pointers, and `discard_message` never calls
`from_transfer_payload`.

These rules are generic; domain chapters keep only their gate and schema:

- **Manual ownership.** A successfully encoded payload owns the duplicated
  native resource. It must be adopted exactly once through
  `from_transfer_payload` or disposed explicitly. UV TCP/pipe, the
  net/TLS/HTTP/WebSocket owners, and `os.InputStream`/`os.OutputStream` export
  `discard_transfer_payload`, which ends in UV's native close; a close attempt
  consumes ownership even when it returns an error status. `fs.File`, the
  `os.InputOutputStream` shell composite, and `sqlite3.Connection` have no such
  helper and require their documented adoption/close recovery.
- **Lossy carriers.** `async.Receiver` coalesces: a newer send replaces an
  unread packet. Discarding or overwriting a packet in either receiver releases
  only transport storage and packet-table entries, never manual payloads, even
  inside closure snapshots. A successful send establishes neither exactly-once
  delivery nor adoption; the application needs its own ownership protocol.
  Stop producers and recover handoffs before closing a receiver.
- **Failure atomicity.** Preflight and duplication failures leave the source
  owner intact (io keeps its first detached pipe when a second duplication
  fails). A failure after detachment can terminalize the composite after
  explicit disposal. There is no transaction around hooks or delivery.
- **Buffered input.** Buffered adapters call `snapshot_pending()` before changing
  ownership and consume the old queue only after native detachment succeeds.
- **Stream eligibility.** UV's preflight (`stream_transfer_status` and
  `titan_uv_transfer_stream_status`) rejects closing streams and streams with
  queued writes or loop-rooted requests; Windows streams with a pending read
  are ineligible even after `read_stop`. Details are in
  [native socket and pipe handoff](libuv-extension-guide.md#native-socket-and-pipe-handoff).
- **Destination loop.** UV keeps the destination loop binding in state-local
  module state: Runtime initialization binds it, shutdown admission clears it,
  and native reconstruction refuses an absent binding.

## Browser subset and verification

`titan.transfer` is part of the [browser standard
library](browser-target.md#the-browser-standard-library) because its imports
(`reflect`, `protobuf`, `gc`, and through them `string`, `peg`, and
`iteration`) reach no native-only module. It is delivered for same-instance
data behavior: encoding, decoding, copying, and discarding packets, the scoped
resource table, and `transfer_load_module` through the image's static preload
table. The packet consumers (`thread`, `lua`, and `async`'s Receivers) are not
available there, so no packet leaves the instance. Nominal encoding and decoding use
protobuf's shared [nesting limit](protobuf-library.md#nesting-limit): 127
accepted record levels on both native and browser targets.

The same-instance cases live in the `transfer.tests` folder owner
(`spec/stdlib/titan/transfer/tests/`), which imports only the browser subset,
owner-local support, and `support.common.titan`, and runs in both the native
aggregate and the browser core stdlib suite. It exercises all three raw
exports: `copy_message` and `discard_message` (nil handling, copied scalar
ownership, refusal to copy a packet with resources, retained and released
resource ownership) and `transfer_load_module` on the current state (an
explicit canonical-name length with trailing bytes beyond it, one pushed
userdata equal to the registered module, and identity on a second load).
`depth_test.titan` (`test_target_depth_boundaries`) derives its depths and
message from `ffi.TITAN_CODEC_DEPTH_LIMIT` and checks, through both
`TransferValue` policies and raw packets on the generated and reflective
paths, that the accepted chain round-trips, that encoding and decoding one
level deeper raise the protobuf nesting error, and that a rejected packet is
still consumed; the same 127/128 boundary holds on both targets. The Task,
thread, and independent-state transfer cases stay native,
in the `async.tests` contributors `transfer_payload_test.native.titan` and
`transfer_scope_reuse_test.native.titan` and in `thread.tests`.
