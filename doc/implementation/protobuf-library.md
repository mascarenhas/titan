# Protocol Buffers library

The public contract is [Protocol Buffers standard
library](../language/standard-library-protobuf.md). The logical `titan.protobuf`
module has four source contributors: `protobuf.titan` owns the public API and
shared scalar/type helpers, `encoder.titan` owns graph traversal,
`decoder.titan` owns wire parsing and reconstruction, and `schema.titan` owns
proto3 declarations. It depends on `reflect` and `string`; it does not depend
on the asynchronous runtime or independent-state wrapper.

## Reflection boundary

The codec uses `RecordType` and `UnionType` descriptors, including nominal
visibility and complete-member visibility flags. Those flags prevent a public
descriptor's omission of private members from being mistaken for permission to
copy a partial object. The checks apply to every encountered nominal, including
local types with public members.

`RecordValue:project` and `UnionValue:project` retain ordinary Titan values and
project native C values through compiler-generated typed member expressions.
Foreign structs and fixed arrays become ordinal const Arrays; full-width
integer bits, floating values, and pointer addresses retain their native
meaning. The codec never interprets userdata offsets, copies struct padding,
or follows a pointer. Long doubles project as exact C hexadecimal strings.

`RecordType:construct` and `UnionType:construct` reconstruct fresh storage using
the same projection protocol. This is reflected default construction, not a
call to a potentially user-defined `new`. It initializes const fields, validates
native assignments and extents, and roots the incomplete destination while
allocating conversions run. Existing ordinary reflection get/set rules remain
unchanged. See [reflection implementation](standard-library-reflect.md).

### Inspected structural-root collaboration

The ordinary compiled API includes narrowly typed collaboration entries used by
`titan.transfer`:

```text
serialize_inspected_record_to_buffer(buf: foreign *void,
                                     candidate: reflect.RecordValue,
                                     context: value)
serialize_inspected_union_to_buffer(buf: foreign *void,
                                    candidate: reflect.UnionValue,
                                    context: value)
deserialize_nominal_buffer_with_context(data: foreign const *void,
                                        length: integer, name: string,
                                        is_union: boolean,
                                        context: value): value
serialize_fields_to_buffer_with_context(buf: foreign *void,
                                        fields: const {reflect.Type},
                                        context: value, ...: value)
deserialize_fields_buffer_with_context(data: foreign const *void,
                                       length: integer,
                                       fields: const {reflect.Type},
                                       context: value): (...: value)

record ResourceCodec
  const identity: value
  const descriptor: reflect.RecordType
  const encode: function (value, value): (integer)
  const decode: function (value, foreign const *void, integer): (value)
end
set_packet_context_provider(provider: function (boolean): (value))
register_resource_codec(
    candidate: value, descriptor: reflect.RecordType,
    encode: function (value, value): (integer),
    decode: function (value, foreign const *void, integer): (value))
find_resource_codec(candidate: value): ResourceCodec?
find_resource_codec_by_name(name: string): ResourceCodec?
foreign function write_resource_index_bytes(dst: *void, index: unsigned int)
foreign function write_resource_index(raw_buf: *void, index: unsigned int): int
```

`buf` must point to a live, initialized `titan_protobuf_buffer`. Each
inspected-root helper records its starting length, resolves `context` via
`packet_context(true)` only when the caller passed `nil`, creates one `Encoder`
carrying `context`, appends the already-inspected root at depth 1, and checks
the appended message size. The caller retains buffer ownership and must provide
its normal native-buffer cleanup; these entries neither initialize nor finalize
that storage. Likewise, `deserialize_nominal_buffer_with_context`,
`serialize_fields_to_buffer_with_context`, and
`deserialize_fields_buffer_with_context` accept the caller's already-resolved
encode or decode `context` (while the public `deserialize_nominal_buffer`,
`serialize_fields_to_buffer`, and `deserialize_fields_buffer` wrappers resolve
`packet_context(true)` / `packet_context(false)` once and delegate to them; a
`nil` `context` carries no attachment/claim authority).
`titan.protobuf` never imports `titan.transfer` or `titan.thread`. Instead,
`transfer` installs its `packet_context` resolver once via
`set_packet_context_provider` and mediates capability registration via
`transfer.register_resource` -> `protobuf.register_resource_codec`.
`record_identity` inspects a candidate userdata's metatable directly
(`TITAN_BRAND == TITAN_RECORD`) without Lua stack or heap allocation; all
erased applications of a generic record (`Sender<|integer|>`,
`Sender<|string|>`, `Sender<|value|>`) share one canonical metatable identity.
At module initialization, `protobuf` validates the state's live
`TITAN_METATABLES_KEY` registry table (`LUA_TTABLE`) and caches that table
reference in traced `resource_nominals`. `find_resource_codec_by_name(name)`
resolves `name` through `resource_nominals[name]` to the live metatable and
then looks up `resource_codecs[identity]`, so modules loaded after `protobuf`
and retried module initializations remain visible and a type name spelling
alone grants no capability. `write_resource_index_bytes` is the single C-only
four-byte little-endian index writer shared by `write_resource_index` (which
reserves and appends four bytes into an owned `titan_protobuf_buffer`) and
`transfer.attach_resource` (which builds the four-byte index string for opaque
hooks).

`Encoder:record_value` / `union_value` still enforce public nominal and complete
member visibility, active-path cycle detection, the 128-level depth limit, and
the normal field/variant traversal with nested custom-hook dispatch. The helper
checks the existing 2 GiB message limit after encoding. No policy is broadened:
root custom-hook and root resource-codec selection remain transfer's
responsibility, and ordinary `protobuf.serialize` retains its structural
public-data rules. See the
[owning API inventory](../language/standard-library-protobuf.md#api) and
[transfer classification](transfer-library.md#flat-packets-and-direct-classification).

## Encoding

The encoder keeps an active-path Map keyed by the original nominal or Array
value. A deferred removal accompanies every entry, so exceptions unwind the
cycle detector. Shared values outside the active path are encoded again. The
encoder does not prevalidate the entire declared type graph; it resolves and
checks descriptors as their values are visited. Union traversal visits the
active payload only; the all-public type flag still rejects private variants
anywhere on that nominal declaration.

All wire accumulation writes into a pluggable, expandable native buffer
(`titan_protobuf_buffer` in `titan/protobuf/native.h`) that grows by amortized
doubling (`titan_protobuf_buf_reserve`) via a pluggable `grow` callback and
`context` pointer. Because serialization calls may raise Lua errors (`longjmp`)
after buffer growth, callers allocate the buffer descriptor with
`owned *titan_protobuf_buffer = foreign titan_protobuf_buffer.new()` so its
`data`, `length`, and `capacity` fields live in GC-owned userdata storage rather
than a stack-spilled automatic C aggregate across `setjmp`/`longjmp`, and pair
`titan_protobuf_buf_init_heap` with `defer ffi.titan_protobuf_buf_free_heap(buf)`
to free `buf->data` on normal exit or unwind. Ordinary string-returning entry
points initialize a heap-backed buffer outside the Lua GC with
`titan_protobuf_buf_init_heap` and materialize the final Lua string once at the
root; `titan.transfer.encode_message` initializes the heap buffer with
`titan_protobuf_buf_init_heap(buf, 0)`, reserves `sizeof(titan_async_message)`
plus at most 64 bytes of the mandatory `name`/`module` trailer upfront via
`titan_protobuf_buf_reserve`, sets `buf->length = sizeof(titan_async_message)`
so the serialized wire payload and trailing `name`/`module` bytes are written
directly after the header prefix without an extra allocation or intermediate Lua
string, and zeroes/populates the `titan_async_message` header once in
`finalize_buf_message` after `titan_protobuf_buf_take_data`. Nested
length-delimited messages reserve
a one-byte length slot at `begin_nested` and patch or shift in place at
`end_nested`, avoiding intermediate per-message writers or string allocations.
Varints use logical shifts on the 64-bit integer carrier, including unsigned bit
patterns represented by negative Titan integers. ZigZag preserves the complete
signed range. Fixed floating and pointer payloads write little-endian bytes
directly into the buffer. Foreign signedness and width checks run before
publication. Structs use member order; nested fixed arrays use their projected
values and target construction validates the actual C extent without evaluating
C expressions in Titan.

`find_transfer_hooks` memoizes the validated `(to_hook, from_hook)` pair (or a
negative sentinel) per nominal record name (`descriptor.name`) in a module-local
Map, and `encode_transfer_payload` shares the module-local
`active_record_payloads` ephemeron Map so nested (`depth > 1`) and root hook
invocations enforce one reentrancy guard without permanently rooting abandoned
encoding graphs. Lexical removals still restore that guard on normal/error exit.
Nested records (`depth > 1`) first check `find_resource_codec_by_name`: when a
registered `ResourceCodec` matches `expected.name`, `Encoder:field` verifies
`record_identity(candidate) == codec.identity`, invokes
`codec.encode(self.context, candidate)` using the packet's carried `context`,
and writes the wire key, length `4`, and four-byte little-endian slot index
directly via `write_resource_index` without calling `reflect.inspect`,
`encode.callable`, or allocating a four-byte Lua string. Other nested records
(`depth > 1`) that provide both `to_transfer_payload` and
`from_transfer_payload` encode as `optional bytes` via their hooks rather than
requiring public fields.

Array wrappers retain slot positions and distinguish absence from an empty
container. Nil slots produce empty element messages. The constness field
preserves a maybe-const Array's actual state. Nil/optional omission and explicit
scalar defaults match the presence markers in generated proto3 schemas.

## Decoding

`WireReader` operates directly on a `const uint8_t *` byte buffer with explicit
`(offset, limit)` bounds, validating each key and length before reading. A
varint has at most ten bytes and its tenth byte contains at most one payload
bit. Length-delimited fields must fit both the remaining source and the protobuf
size limit. Unknown groups are skipped with a bounded, matching start/end
field-number walk.

Parsed `WireField` entries record integer bits or `(offset, length)` slices into
the underlying byte buffer without allocating intermediate Lua strings. Singular
scalars select their final occurrence. Single-occurrence embedded messages and
union variants parse their child fields in place from the parent buffer slice;
repeated occurrences of a singular embedded message or union variant concatenate
their slices before parsing child fields, implementing protobuf merge behavior.
Unknown fields do not change the selected union variant.

Each parsed message keeps its ordered field Array. Empty and single-field
messages answer lookups directly. The first lookup in a multi-field message
builds a sparse Map from field number to the last Array index, linking each
field to the previous occurrence of that number. Later scalar lookups use the
Map; message merging follows only matching links and restores their original
encounter order. A single occurrence returns its bytes directly. The Map grows
with encountered field numbers, never the largest numeric tag. Ordered-only
Array and union readers allocate no index. Building the index takes time linear
in the parsed field count; subsequent scalar lookups take expected constant
time, and message merging visits only matching occurrences. Every merged
occurrence's wire kind is validated, and encounter order governs Array slots
and oneof replacement.

Schema-directed decoding requires each non-optional field, validates the wire
kind, and constructs children before calling reflected construction for the
parent. When `decode_field` visits a record type with a registered
`ResourceCodec` (`find_resource_codec_by_name`), it validates wire kind `2` and
invokes `codec.decode(message.context, message.base + field.offset,
field.length)` directly on the borrowed wire slice using the carried
`Message.context`, without allocating a four-byte Lua string, calling a
reflected hook closure, or re-inspecting the constructed wrapper. No partially
constructed value is published after a failure. Type lookup uses the
destination state's initialized nominal registry; the nominal helper checks
both name and requested record/union kind. It does not guess a module name or
execute a module loader.

The reader limits nesting and message size. Native reconstruction supplies the
final C range, qualifier, fixed-array extent, and construction checks. A decoded
pointer remains a borrowed address. No GC object from the source state enters
the destination heap.

## Anonymous root messages

`serialize_fields` accepts an ordered `const {reflect.Type}` descriptor and an
exact-arity variadic value run. It calls the same `Encoder:field` operation used
by reflected records, with the same declaration-order field numbers and root
depth. `deserialize_fields` parses one ordinary message and calls `decode_field`
for each declared type. Its explicit result range preserves the descriptor's
field count even when the final results are nil. Neither entry constructs a
nominal descriptor or changes the visibility checks on nested nominal values.

The descriptor remains in the hook's module; only bytes cross the state
boundary. Resource hooks describe pointer tokens, scalar state, and child
payload strings this way. Closure snapshots describe Arrays of converted
`TransferValue` policies and explicit-policy flags, passing the packet's
already-resolved `ResourceScope` to
`serialize_fields_to_buffer_with_context` and
`deserialize_fields_buffer_with_context`. Nested closures and custom
payloads are already byte strings, so this use does not introduce a recursive
native transfer representation or a separate field codec.

## Schema generation

The schema builder walks declared descriptors, separately from optimistic value
encoding. A nominal-name Map terminates recursive schema references. Nominal
identifiers use injective byte escaping, including underscores; structural
wrapper names derive from the owning field/part path. The encoder and schema
builder share field-number assignment, including the protobuf reserved range.

Every scalar field is proto3 `optional`; messages already carry presence. Union
variants are `oneof` members whose nested messages support empty and multipart
payloads. Arrays have a repeated slot-message field, rather than scalar packed
fields, because nil positions and nested Arrays need explicit slots. Titan
strings use protobuf bytes so arbitrary byte sequences round-trip.

## Integration and verification

Custom record transfer hooks are dispatched by `titan.transfer` before its
structural protobuf fallback at the root, while `titan.protobuf` dispatches
`to_transfer_payload` and `from_transfer_payload` for nested record fields
(`depth > 1`) inside public records, unions, and Arrays, emitting them as
`optional bytes` on the wire. The codec's `serialize` entry point retains its
public-field policy at `depth == 1`. Custom payloads and closure snapshots are
immutable byte strings before they enter the native transfer boundary.

The Unix and Windows standard providers include `titan.protobuf`, its Lua shim,
and its native tests in the shared inventory. `titan.lua` and `titan.async`
depend on the codec through `titan.transfer`, so its loader
is available in independent-state preload snapshots and Receiver-only
applications. Explicit nominal carriers retain
their defining modules, nominal names, and bytes. Closure reconstruction uses
the codec to decode its snapshot against the receiving state's initialized types;
no operation reads another state's reflection descriptors.

Tests belong in `spec/stdlib/titan/protobuf/`, with transfer lifecycle cases in
the Lua/async native owners and reflection/code-generation tests in their
existing layers. Cover full-width scalars, binary strings, custom constructors,
const fields, foreign aggregate projections, nil Array positions, graph
rejection, unknown fields, merge rules, malformed inputs, and schema/wire
agreement with an independent protobuf implementation. Foreign exportability
also needs a source-free compiled-consumer gate using the real declaring C
header.
