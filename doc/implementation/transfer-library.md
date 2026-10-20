# Transfer policy implementation

`titan/transfer.titan` owns `TransferValue`, native packet
encoding/decoding/copying/disposal (`encode_message`, `decode_message`,
`copy_message`, `discard_message`), packet-scoped resource attachment/claim
(`attach_resource`, `claim_resource`), `transfer_load_module`, custom-record
hook selection, immediate closure capture conversion, and destination
reconstruction. Its common native packet and resource-table header
(`titan/transfer_native.h`) is separated from the receiver slot header
(`titan/async_receiver_native.h`). `titan.transfer` imports `reflect`,
`protobuf`, and `gc`, without depending on `uv`, `async`, or `thread`. `async`
exports a transparent alias of `TransferValue`.

## Flat packets and direct classification

Nominal and custom-record packets carry the actual defining module, qualified
nominal name, and opaque bytes. A closure packet carries its defining module,
immutable entry token, and opaque snapshot bytes. The `titan.lua` worker
boundary copies scalar fields and strings over its separate carrier; it does
not walk capture graphs, retain Lua objects, or attach packet-scoped resources.

Transfer uses direct classification paths before falling back to general
reflection; `encode_packet` additionally recognizes registered resource roots:

1. **Direct scalar Lua tags (`scalar_message_kind`, `scalar_value_to_message`, `new_scalar_message`)**:
   `scalar_message_kind` inspects the raw `TValue` tag before `encode_message`
   queries `current_execution()` or allocates a `ResourceScope`. It returns the
   non-negative `titan_async_message_kind` for `LUA_TNIL`, `LUA_TBOOLEAN`,
   `LUA_TNUMBER` (testing `LUA_VNUMINT` to keep integers distinct from integral
   floats and `-0.0`), `LUA_TSTRING` (preserving exact byte length),
   `LUA_TLIGHTUSERDATA`, `LUA_TTHREAD` (borrowed `*lua_State`), unbranded or
   unknown-brand `LUA_TUSERDATA` whose metatable has no metatable (borrowed
   payload pointer via `lmacro_getudatamem`), and `LUA_TFUNCTION` for light C
   functions and zero-upvalue C closures (rejecting `NULL` C functions and
   non-Titan C closures with upvalues). If `userdata.metatable.metatable ~= nil`,
   `scalar_message_kind` returns `-1`. In `encode_message`, this defers any
   `__index` metamethod triggered by a brand lookup until the encode scope is
   established, during resource-capability lookup or `reflect.inspect` (which
   still encodes `is_lua_userdata` via `new_scalar_message`).
   `TransferValue.from_value` shares the probe but does not establish a scope
   before its `reflect.inspect` lookup. Known Titan userdata brands
   (`TITAN_ARRAY..TITAN_OWNED`) and branded Titan closures likewise return `-1`.
   Explicit scalar `TransferValue` policies and non-negative
   `scalar_message_kind` results use `new_scalar_message`, which checks
   `length <= SIZE_MAX - sizeof(titan_async_message)`, allocates
   `sizeof(titan_async_message) + length` directly on the C heap, zeroes the
   header, and writes the scalar fields and optional string bytes in one pass
   without staging an automatic `titan_async_message` or using the packet-copy
   path. Explicit `is_record`, `is_union`, `is_closure`, and `is_record_payload`
   policies (with `owner == nil`) and opaque custom-hook roots (with
   `owner == scope.native`) use `new_nominal_message`, which validates `length`,
   `name_length`, and `module_length` against `SIZE_MAX`, computes the complete
   allocation size via `packet_storage_size`, allocates the heap packet once,
   zeroes the header, copies the payload and `name`/`module` strings, and
   (when `owner ~= nil`) commits the scope's pending attachments via
   `commit_resources` without automatic header staging.
2. **Demand-driven Titan closure classification**: When `LUA_TFUNCTION` is a C
   closure with `nupvalues >= 5` and `upvalue[3] == TITAN_BRAND`,
   `scalar_message_kind` returns `-1` and transfer dispatches directly to
   `snapshot_closure` or `encode_packet`'s closure path (`project_closure_captures`).
   `transfer_closure_entry` validates the closure header, brand, module
   userdata, and manifest entry (`entry.native` and `entry.strict`) directly in
   C without calling `reflect.inspect`. `encode_packet` runs
   `project_closure_captures` once before initializing the packet buffer, so
   captures and custom hooks execute once and the defining module's byte length
   is known before buffer reservation. Neither root nor nested closure transfer
   hydrates reflection's `FunctionType` signature text, while explicit
   `reflect.inspect` calls preserve eager full `FunctionValue` / `FunctionType`
   descriptors without needing a signature cache.
3. **Registered nominal resource capability (`protobuf.find_resource_codec`)**:
   In `encode_packet`, before scalar or reflection dispatch, a `LUA_TUSERDATA`
   candidate is checked against `protobuf.find_resource_codec(candidate)` by its
   canonical erased metatable (`TITAN_BRAND == TITAN_RECORD`). On a hit
   (`thread.Sender` or `thread.Receiver`), `encode_packet` resolves the
   declaring module (`nominal_module`) and `codec.descriptor.name`, computes the
   complete packet size including header, index, nominal metadata, and aligned
   one-entry attachment tail, and reserves it in one heap-backed buffer
   **before** calling `codec.encode(scope, candidate)`. It then sets
   `buf.length = sizeof(titan_async_message)`, writes the four-byte
   little-endian slot index via `protobuf.write_resource_index`, and calls
   `finalize_buf_message` to append `name` and `module` and fill the packet
   header in the same allocation prefix—producing the
   `TITAN_ASYNC_MESSAGE_RECORD_PAYLOAD` packet in one heap allocation with no
   Lua index string, no reflective hook invocation, and no staged `copy_message`.
   `TransferValue.from_value` and `TransferValue:to_value` likewise check
   `protobuf.find_resource_codec` (when `mt ~= nil and mt.metatable == nil`,
   preserving the single reflective lookup for metatable-of-metatable
   candidates) and `protobuf.find_resource_codec_by_name` before reflective
   hook dispatch, passing `packet_context(true)` / `packet_context(false)` to
   the registered capability while retaining the four-byte little-endian index
   string inside `is_record_payload` (including for closure-captured endpoints).
4. **Generated nominal codec**: after the root resource-capability and closure
   checks and before `reflect.inspect`, `encode_packet` asks
   `protobuf.find_generated_codec(candidate)`. A bound generated codec writes
   the record or union through the ordinary owned packet buffer
   (`init_packet_buffer` with the codec's name and the `nominal_module`, then
   `protobuf.serialize_generated_to_buffer` and `finalize_buf_message` with
   the codec's record or union kind), carrying the packet's `ResourceScope` as
   its context. It allocates no root inspection. Endpoint fields and other
   registered resources attach through the reflective resource branch with
   that scope, allocating no `Encoder`; hooked, Array, and foreign fields use
   the reflective field encoder, through one `Encoder` and cycle Map created
   on the root's first such field and reused for the rest, so attachment order
   and errors are those of the reflective root. Decoding reaches the generated
   decoder through
   `protobuf.deserialize_nominal_buffer_with_context` after the unchanged
   demand-driven `initialize_nominal_raw`, and claims resources the same way. See
   [generated nominal codecs](protobuf-library.md#generated-nominal-codecs).
5. **Single structural root inspection and carried packet context**: When a
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
   (128), and 2 GiB message-size checks. They also try the generated codec
   first, as do public `protobuf.serialize` and `protobuf.serialize_to_buffer`.

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
(`titan_async_message`) serialization for `titan.thread` and `titan.async`'s
coalescing `Receiver` without requiring source imports across modules. Scalar
and explicit-policy encoding and C-only scalar decoding acquire no scope and
leave any enclosing scope intact. For structural records, unions, and closures,
`init_packet_buffer` checks
`name_length` and `module_length` against `SIZE_MAX - sizeof(titan_async_message)`,
initializes an `owned *titan_protobuf_buffer` with
`titan_protobuf_buf_init_heap(buf, 0)`, reserves
`sizeof(titan_async_message) + min(name_length + module_length, 64)` upfront via
`titan_protobuf_buf_reserve` (crediting up to 64 bytes of mandatory metadata so
bounded packets share the existing doubling sequence without increasing retained
capacity), and sets `buf.length = sizeof(titan_async_message)`. Because
serializers only append at `buf.length` and never read the prefix—and failure
cleanup (`titan_protobuf_buf_free_heap`) frees `buf->data` without inspecting
header fields—`init_packet_buffer` leaves the header prefix uninitialized until
`finalize_buf_message` completes the trailing reservation, zeroes
`sizeof(titan_async_message)`, populates the packet header and attachment tail,
and detaches the buffer with `titan_protobuf_buf_take_data`.

The shared buffer's bulk-write rule grows to
`needed + max(256, needed / 8)` after a single reservation exceeding four times
the current capacity (using 64 as the minimum), rather than rounding the large
payload up to the next power of two. Division rounds down: for `needed` of at
least 2,048 bytes the slack is at most 12.5% of that need; smaller bulk requests
leave 256 bytes. If the addition would exceed `SIZE_MAX`, growth requests
exactly `needed`. This slack is separate from the initial 64-byte metadata
credit: the initial reservation stays below the bulk threshold and, like every
small write, uses ordinary power-of-two growth. After a bulk growth, the doubling
branch starts from the largest power of two no greater than
`max(capacity, 64)`, so later growth rejoins that sequence (or requests exactly
`needed` if doubling would overflow). A 64 KiB byte field needs only one bulk
growth, with room for proportional trailing fields, name/module bytes, and the
aligned one-endpoint tail. `finalize_buf_message` reserves the actual trailer
and entry count before detachment; trailing data that exceeds the slack can
require a second payload-sized reallocation through normal growth, even when
rounding the original field up to the next power of two would have left enough
room. See [buffer growth](protobuf-library.md#encoding).

Decode reads directly from the packet's byte slices using
`protobuf.deserialize_nominal_buffer_with_context` (passing `scope` once for
`RECORD` and `UNION` packets, together with the `reflect.NominalType?` that
`initialize_nominal_raw` returns from its registry lookup, so protobuf neither
repeats the lookup nor wraps the descriptor in a `reflect.Type`) and
`protobuf.deserialize_fields_buffer_with_context` (passing `scope` through
`restore_closure_from_buffer` for `CLOSURE` packets, matching `encode_packet`'s
`protobuf.serialize_fields_to_buffer_with_context` call). For a `RECORD_PAYLOAD` packet, after
`initialize_nominal_raw` ensures the destination module is loaded in the
receiving state, `decode_message_worker` checks
`protobuf.find_resource_codec_by_name(name)`: registered resource types invoke
`codec.decode(scope, message.bytes, message.length)` directly on the borrowed
packet slice without allocating a four-byte payload string or running a
reflected hook, while other custom-hook records copy the payload string and
dispatch `from_transfer_payload`. The native scope owner disposes the packet and
unclaimed attachments after reconstruction or an error; already claimed endpoint
wrappers retain their own finalized ownership.

### Consuming raw-slot decode

Decode is an ordinary public Titan function, available through ordinary
compiled imports:

```text
function decode_message(slot: foreign *(*void)): value
```

It decodes into the calling state's `L`. Its generated preamble
(`luaC_checkGC` and `titan_ensure_stack` for its own frame) runs before the body
reads `slot`. A memory or stack error there propagates with `slot[0]` still
holding the packet, which the caller's mandatory
`defer discard_message(raw)` disposes of. The body then:

1. raises `"transfer: invalid packet owner slot"` for a nil `slot`;
2. for a non-nil `slot[0]`, reserves the single result slot with
   `lua_checkstack(L, 1)`, which reports failure without `longjmp`. On failure
   it clears `slot[0]`, disposes of the packet via `discard_message`, and raises
   `"transfer: cannot reserve packet operation stack"`. Otherwise
   `decode_scalar_message` checks whether `message.kind` is an allocation-free
   scalar (`NIL`, `BOOLEAN`, `INTEGER`, `FLOAT`, `STATE`, `POINTER`, or
   `FUNCTION` with `message.function ~= nil`, pushed via
   `lua_pushcclosure(L, message.function, 0)`). On a match it pushes the single
   noncollectable value in C; `decode_message` clears `slot[0]`, disposes of the
   packet, copies the value with `lua_totvalue`, restores the stack top, and
   returns without entering a protected region, looking up any worker, or
   allocating a `ResourceScope`;
3. otherwise (allocating kinds, empty slots, and malformed `FUNCTION` packets)
   calls the local `decode_message_worker(slot)` inside one inline Titan
   `catch`, a `setjmp` boundary in the same C function. The catch clears
   `slot[0]`, passes any residual owner to C-only `discard_message`, and
   re-raises with a bare `raise`, which pins the original error value and
   traceback (see [trace pinning](error-handling.md#trace-pinning)).

No registry entry, dispatch thunk, `lua_pcallk`, `lua_callk`, or message
handler is involved, and a successful decode leaves the caller's stack top
unchanged.

Inside `decode_message_worker`, `STRING` packets root-copy their bytes via
`copy_native_bytes` while `slot[0]` still owns the packet, then clear the slot
and dispose of the packet before returning. Malformed `FUNCTION` packets with a
`NULL` pointer raise `"cannot transfer a NULL Lua C function"` with the packet
still in `slot[0]`. Both paths run **before** `current_execution()`,
`acquire_resource_scope()`, and `move_slot_to_scope`: neither can claim resource
attachments, so they skip `ResourceScope` acquisition. Only nominal packets
(`RECORD`, `UNION`, `CLOSURE`, `RECORD_PAYLOAD`) acquire either a fully retired
pooled `ResourceScope` or a fresh inert frame. Only fresh creation registers the
finalizer, before granting authority or native ownership; pooled frames are
already finalizable. The worker installs lexical exact-top restoration/native
disposal and inserts the scope before `move_slot_to_scope` moves and clears the
caller's slot into the scope's native cell. Ordinary worker-entry failure,
module initialization, primitive decode failure, and scope-preparation failure
therefore leave the input in the caller's slot for `decode_message`'s catch;
after commit the scope owns it, and the catch finds an empty slot.

| Outcome | Caller slot | Lua stack |
| --- | --- | --- |
| value returned | nil; packet disposed | unchanged |
| error raised by the body | nil; residual packet disposed before propagation | restored by the catching boundary |
| error raised by decode's own entry preamble | unchanged; the caller's guard disposes | restored by the catching boundary |
| nil slot address | no valid slot | unchanged |

The caller passes its actual guarded `foreign *void` local. An exact pointer
local supplied to the `foreign *(*void)` parameter uses the checker's
`mutable_c_address` coercion, so codegen passes `&local`
([contextual object-pointer conversion](c-ffi-expressions.md#contextual-object-pointer-conversion)).
Ordinary Titan calls record no `_c_mutated_decls`, so the decode call neither
marks the local as written for spill analysis nor refreshes an existing spill.

The safety of the caller's guard therefore depends on the local never being
spilled at all. Spills are per declaration across the whole generated C
function: `coder._analyze_try_spills_stat` marks a Decl `_needs_spill` when any
protected body (a `catch`-trailed block or a `defer` tail) writes it, by
declaration, assignment, or `_c_mutated_decls` from a mutating C call, and that
body's catch, finally, or post-try continuation reads it (a catch that has its
own finally is analyzed the same way). Every later recovery boundary whose spill
scope contains the Decl then reloads it from the spill (`spill_reload`), and
only Titan assignments and C out-argument calls update the spill. If any
region, including one that ended before the guard was installed, spilled the
guarded local, a decode error would make the guard's recovery reload the stale
pre-decode packet pointer and discard the packet a second time. For example,
`local raw = nil; do raw = encode_message(v) catch return nil end` followed by
`defer discard_message(raw); return decode_message(raw)` double-frees when
decode raises; a gcc `-O2` and a clang `-O2` AddressSanitizer probe both
confirm this, while the unspilled forms run clean.

An unspilled local holds no volatile copy. ISO C leaves an automatic object
changed between `setjmp` and `longjmp` indeterminate, so reading the local
after recovery relies on the same accepted compiler assumption as native
registrar wait cells: because its address escapes to the callee, the compiler
keeps it in memory and recovery observes decode's clear
([longjmp-safe spills](c-ffi-expressions.md#longjmp-safe-aggregate-spills)).

Every production caller (the `thread.Receiver` receive paths, child bootstrap,
cancellation delivery, terminal-status reconstruction, and
`async.Receiver:wait`) gives the local its packet in its own declaration or
through one C out-argument call that no reading region encloses, installs the
guard immediately, and never writes the local afterward. `Receiver:wait`
declares a fresh local per loop turn and installs its guard only after
`receiver_take_native` reports a taken packet. The generated C for these
callers contains no spill for the guarded local. Lua code cannot call
`decode_message`: generated Lua entries have no dynamic coercion for raw C
pointer parameters.

Decode enters Lua, may initialize transfer and destination modules, and may run
decoders; it cannot use a closed state and is not part of the no-Lua release
chain. Raw `discard_message` still needs neither a state nor a Runtime.

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
(`entries`, `count`; no committed `capacity`) in `titan_async_message`. Each
entry (`titan_transfer_resource`) holds `(void *resource,
titan_transfer_resource_fn release)` (16 bytes on LP64) with no separate
`claimed` field: a `nil` `resource` pointer marks a consumed unit while
`release` is retained so claim validation still checks resource kind before
duplicate consumption. Entries contain only native pointers and C-ABI
callbacks—no Lua/Titan GC objects or state-bound closures. Committed entries
live in the aligned tail of the `titan_async_message` allocation itself; `entries`
is `nil` when `count == 0` and otherwise points inside that single packet block.
Changing `titan_async_message` or `titan_transfer_resource_table` alters the
native packet contract while keeping ABI 2, SDK/package 0.6/0.6.0, and
language-server API 1 unchanged, so every provider, consumer, and native fixture
must be cleanly rebuilt with no mixed-layout shim.

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

- **Execution-local exact-top authority and bounded state-local frame reuse
  (`ResourceScope`)**: `resource_scopes` maps the actual current Lua thread
  value, obtained by `current_execution()` with `lua_pushthread`, to that
  execution's active top `ResourceScope`. It is an ephemeron Map, not a
  raw-address registry: a reachable suspended execution keeps its active scope
  alive through its stack. A scope has no back-edge to its execution, so an
  unreachable execution does not remain rooted through the Map's value.
  Each `ResourceScope`
  stores only `encoding` (direction), an inline `titan_transfer_scope_owner`
  native cell (`resources{entries,count}`, `capacity`, `message`, and
  `inline_entries[4]`, totaling 96 bytes on LP64), a borrowed `message` pointer
  for decode claim lookup, and `free_next` for the state-local idle free stack.
  The current `execution` key and enclosing `previous` frame remain in the
  lexical locals of `encode_message` and `decode_message_worker`, so a scope
  frame never retains a strong edge back to its execution thread or parent frame.
  `acquire_resource_scope()` pops a retired frame from the state-local
  `idle_resource_scopes` stack (hard-bounded at `idle_resource_scope_limit = 8`
  frames per Lua state, a private retention bound rather than a user contract,
  independent of coroutine/Task identity so Task-per-message callers share the
  pool); on an empty stack it allocates an inert
  `ResourceScope` and registers `gc.finalizable(fresh, finalize_resource_scope)`
  before granting execution authority or native ownership. Both entry points
  increment the state-local `active_scope_count` immediately before registering
  their lexical retirement `defer`, so no normal or error exit can uncount a
  frame it never counted. Lexical deferred
  retirement stays inline (introducing no fallible ordinary helper entry after
  packet commitment) and runs in exact order:
  1. restore `resource_scopes[execution] = previous` and decrement
     `active_scope_count`;
  2. call C-only `dispose_scope(scope.native)`, which detaches `message`,
     `entries`, `count`, and `capacity`, releases any uncommitted scratch units
     via `dispose_resource_entries`, frees `entries` only when
     `capacity > TITAN_TRANSFER_INLINE_RESOURCES` (`4`), disposes any owned
     decode `message` via `discard_message`, and zeroes the complete
     `titan_transfer_scope_owner` cell with `memset`;
  3. clear `scope.message = nil` and `scope.encoding = false`;
  4. push `scope` onto `idle_resource_scopes` only when
     `idle_resource_scope_count < 8`.

  Generated `defer`/`catch` recovery reaches this cleanup under sustained
  `LUA_ERRMEM` without interning strings: the compiler roots its recovery keys
  and empty traceback in private module slots before generated code can run.
  Transfer needs no separate string-root workaround. See
  [error recovery](error-handling.md) for the allocation-free recovery arm and
  the separate, potentially allocating Lua `__close` behavior.

  Idle pooled frames hold no native ownership and grant no authority. Deeper
  nested bursts (`> 8` concurrent frames in one state) retire their overflow
  frames normally and leave them for ordinary GC reclamation; when
  `finalize_resource_scope` later runs on an already-retired overflow frame, its
  zeroed native cell makes `dispose_scope` a no-op. Only the current execution's
  exact top authorizes attachment or claim; no older matching phase is searched.
  Same-stack protobuf fields, opaque hooks, and closure capture conversion share
  the top, while nested structural/hook packet work pushes its own frame.
  Scalar/policy encoding, C-only scalar decoding, and scope-free protected
  `STRING` / `NULL`-`FUNCTION` decoding leave the enclosing frame intact without
  acquiring another. Other Tasks and separately resumed child
  Coroutines inherit no packet authority. An abandoned
  active execution stack that never runs its lexical `defer` never returns its
  frame to `idle_resource_scopes`; `finalize_resource_scope` reclaims its
  unfinished scratch units, heap spill, and owned packet natively. This
  isolation/abandonment mechanism does not make yielding transfer hooks
  supported. Standalone protobuf/policy conversion opens no scope and cannot
  manufacture ownerless endpoint references.

  Every resolution of the current top frame goes through
  `current_resource_scope()`. When `active_scope_count` is zero, no frame is
  installed for any execution in the state, so it returns nil before calling
  `current_execution()` (`lua_checkstack`, `lua_pushthread`, and the `defer`
  frame) or probing the ephemeron Map; this keeps standalone
  `protobuf.serialize`/`deserialize` and policy conversion free of execution
  lookup. A frame abandoned on a never-resumed stack is never uncounted, so the
  count can only over-estimate: the full exact-top lookup then runs and returns
  only the current execution's own frame, if any. A positive count therefore
  never grants authority; it only disables the shortcut.
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
  standard missing-scope error. `TransferValue.from_value` and
  `TransferValue:to_value` pass `packet_context(true)` and
  `packet_context(false)` to the registered `ResourceCodec` callbacks, while
  public `attach_resource` and `claim_resource` continue to resolve the exact
  top through `current_resource_scope()` on every call for opaque user hooks.
- **Inline scratch cell, heap spill, and pre-detach trailing reservation
  (`reserve_resource`, `packet_storage_size`, `commit_resources`)**: After
  checking the top encode scope and non-nil `resource`, `retain`, and `release`
  pointers, `reserve_resource(scope.native)` reserves a scratch slot **before**
  `attach_reserved` calls `retain(resource)`. The first
  `TITAN_TRANSFER_INLINE_RESOURCES` (`4`) attachments use
  `scope.native.inline_entries` directly (`capacity = 4`) with no heap
  allocation, which covers packets carrying up to four endpoint occurrences. A
  fifth attachment spills to an 8-entry heap array via one `malloc` and copies
  the four inline entries (the inline address is never passed to
  `realloc`); a ninth and later growth double `capacity` via `realloc`, saturating at
  `TITAN_TRANSFER_INVALID_INDEX = 0xffffffff` (valid slot indexes
  `0..0xfffffffe`) and checking `SIZE_MAX / sizeof(titan_transfer_resource)`. A
  failed spill or growth leaves all prior units and the existing scratch buffer
  owned by `scope.native` for native rollback. Once `retain` returns,
  `attach_reserved` writes `{ resource, release }` and increments `count`. Every
  packet-producing path reserves header, payload, metadata, alignment padding,
  and the exact trailing entry bytes before buffer detachment or allocation so a
  detached packet is never reallocated:
  - `packet_storage_size(content_size, count)` returns `content_size` when
    `count == 0` (adding no alignment padding or tail) and otherwise computes
    `align_up(content_size, alignof(titan_transfer_resource)) + count * sizeof(titan_transfer_resource)`
    with `SIZE_MAX` overflow checks on alignment padding, byte addition, and
    entry multiplication.
  - Structural records, unions, and closure snapshots call
    `finalize_buf_message`, which reserves `storage_size - buf.length` in the
    expandable buffer before zeroing and writing the header and `name`/`module`
    trailers, derives all interior pointers after that final reservation, calls
    `commit_resources(msg, owner, storage_size)` to `memcpy` the active scratch
    units into the aligned packet tail and reset `owner.resources.count = 0`, and
    detaches `buf.data`.
  - Registered root endpoints pre-reserve the known one-entry `storage_size`
    before attaching the endpoint and finalize in place.
  - Opaque root custom-hook payloads call `new_nominal_message(...,
    scope.native)`, which computes `storage_size` once (including the aligned
    tail for `scope.native.resources.count`), allocates the single heap packet,
    copies the payload and `name`/`module` strings, and moves the scope's units
    via `commit_resources`.
  - Scalar packets (`new_scalar_message`) and explicit-policy packets
    (`new_scalar_message` or `new_nominal_message(..., nil)`) open no scope and
    carry an empty `resources` table (`{ nil, 0 }`).
- **Validated claim and finalizer-first adoption (`ResourceScope:claim`,
  `claim_resource`, and `claim_registered_resource`)**: Checks the top decode
  scope, requires `length == 4`, decodes the four-byte
  little-endian unsigned slot index (inverse of
  `protobuf.write_resource_index_bytes`), checks `index ~= 0xffffffff` and
  `index < scope.message.resources.count`, checks
  `expected_release ~= nil and entry.release == expected_release`, and checks
  `entry.resource ~= nil`. It then sets `entry.resource = nil` (leaving
  `entry.release` intact so a subsequent wrong-kind claim on the same consumed
  slot still fails with kind mismatch before duplicate claim) and returns
  `resource` with no subsequent allocation or yield. Both registered endpoint
  constructors and hook decoders allocate their inert wrapper (`native = nil`)
  and register `gc.finalizable` **before** claiming, then assign `native`
  immediately. Thus a failure before or during the
  claim leaves the retain owned by the packet's trailing table, while a failure in
  a later field leaves already-claimed wrappers owned by the destination GC and
  disposes only the remaining non-nil packet entries.
- **Reentrant C-only disposal (`dispose_resources`, `discard_message`) and
  `copy_message`**: `dispose_resources` detaches `entries` and `count` from the
  table header (`table.entries = nil`, `table.count = 0`) before
  `dispose_resource_entries` iterates over `0..count - 1`, clears
  `entry.resource = nil`, and calls `release(resource)` on each non-nil entry.
  Detaching first ensures recursive release paths (such as releasing the last
  `thread.Receiver`, which drains its channel and discards nested packets) cannot
  observe the table as still owned. Because committed `entries` points into the
  packet's own trailing bytes, `discard_message(raw)` frees only the single
  `message` allocation after `dispose_resources` finishes—without entering Lua,
  loading modules, running user decoders, or requiring a Runtime. Public foreign
  `copy_message(raw)` checks `resources.entries == nil` and
  `resources.count == 0` directly and refuses any packet with attachments,
  copying only attachment-free packets.

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

`async.Receiver` delivery is lossy: native notifications coalesce and newer
sends replace unread slot packets before `wait()` takes them. Overwriting or
discarding a packet in `async.Receiver` or `thread.Receiver` releases only
transport storage and any packet-table entries registered via `attach_resource`,
without invoking manual resource disposal hooks. A successful send therefore
does not establish exactly-once delivery or adoption for manual-handoff
resources, including native tokens hidden inside closure snapshots; the
application must retain an ownership protocol outside the lossy packet.

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
