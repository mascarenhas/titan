# Protocol Buffers standard library

Import `protobuf` in Titan, or require `titan.protobuf` in Lua. The module copies
public record and union values using the [Protocol Buffers wire
format](https://protobuf.dev/programming-guides/encoding/). It also emits the
matching proto3 schema. Reflection supplies the declared types and fresh
field-by-field construction; decoding never calls a user-defined `new`.

```titan
local protobuf = import "protobuf"
local reflect = import "reflect"

record Message
  const sequence: integer
  text: string
end

function round_trip(): Message
  local original = Message.new(7, "hello\0world")
  local bytes = protobuf.serialize(original)
  local target = reflect.Type.is_named(reflect.NamedType.new("example.Message"))
  -- This complete module is named example.
  return protobuf.deserialize(bytes, target)
end
```

## API

```text
serialize(candidate: value): string
serialize_to_buffer(buf: foreign *void, candidate: value)
serialize_inspected_record_to_buffer(buf: foreign *void,
                                     candidate: reflect.RecordValue,
                                     context: value)
serialize_inspected_union_to_buffer(buf: foreign *void,
                                    candidate: reflect.UnionValue,
                                    context: value)
deserialize(bytes: string, descriptor: reflect.Type): value
schema(descriptor: reflect.Type): string
deserialize_nominal(bytes: string, name: string, is_union: boolean): value
deserialize_nominal_buffer(data: foreign const *void, length: integer,
                           name: string, is_union: boolean): value
deserialize_nominal_buffer_with_context(data: foreign const *void,
                                        length: integer, name: string,
                                        is_union: boolean,
                                        context: value): value
serialize_fields(fields: const {reflect.Type}, ...: value): string
serialize_fields_to_buffer(buf: foreign *void,
                           fields: const {reflect.Type}, ...: value)
serialize_fields_to_buffer_with_context(buf: foreign *void,
                                        fields: const {reflect.Type},
                                        context: value, ...: value)
deserialize_fields(bytes: string, fields: const {reflect.Type}): (...: value)
deserialize_fields_buffer(data: foreign const *void, length: integer,
                          fields: const {reflect.Type}): (...: value)
deserialize_fields_buffer_with_context(data: foreign const *void,
                                       length: integer,
                                       fields: const {reflect.Type},
                                       context: value): (...: value)
find_transfer_hooks(descriptor: reflect.RecordType, prefix: string):
    (reflect.MethodType?, reflect.StaticFunctionType?)
encode_transfer_payload(candidate: value, encode: reflect.MethodType,
                        err_msg: string): string

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

The root must be a public Titan record or union. `deserialize` and `schema`
accept its record/union descriptor or a named descriptor that resolves to it.
`deserialize_nominal` performs the same operation using a fully qualified name,
and checks the requested nominal kind. It is also the independent-state
argument conversion entry. Unknown names raise; lookup does not load modules.

`serialize_to_buffer` and `serialize_fields_to_buffer` append encoded wire bytes
into a caller-initialized `titan_protobuf_buffer` (`buf`) without allocating an
intermediate Lua string. `deserialize_nominal_buffer` and
`deserialize_fields_buffer` decode directly from a borrowed `const void *` byte
slice of length `length`. `find_transfer_hooks` returns a record's validated
`(to_transfer_payload, from_transfer_payload)` pair as its reflected
`MethodType` and `StaticFunctionType` (memoized per nominal record name
`descriptor.name`), or `(nil, nil)` when the record has neither hook; `prefix`
(`"protobuf"` or `"transfer"`) only labels its validation errors.
`encode_transfer_payload` invokes that `encode` method under the shared
active-record cycle guard and raises `err_msg` if `candidate` is already active.

The caller retains ownership of a raw buffer and must keep its descriptor and
any `context` owner alive until serialization returns, then free or detach its
storage using the matching native buffer operations. The `grow` callback can be
invoked synchronously while appending. Small writes retain geometric growth;
a single bulk reservation uses bounded extra capacity instead of rounding a
large payload up to the next power of two. Buffer capacity and allocation
counts are not part of the serialized wire format; see the
[implementation growth policy](../implementation/protobuf-library.md#encoding).

`serialize_inspected_record_to_buffer`, `serialize_inspected_union_to_buffer`,
`deserialize_nominal_buffer_with_context`,
`serialize_fields_to_buffer_with_context`,
`deserialize_fields_buffer_with_context`, `ResourceCodec`,
`set_packet_context_provider`, `register_resource_codec`,
`find_resource_codec`, `find_resource_codec_by_name`,
`write_resource_index_bytes`, and `write_resource_index` are ordinary compiled
collaboration entries used by `titan.transfer`. `buf` must point to a live,
initialized `titan_protobuf_buffer`, just as for `serialize_to_buffer`; the
inspected-root helpers append to it and do not own or finalize the buffer.
Passing the already-inspected `reflect.RecordValue` or `reflect.UnionValue` and
the packet's resolved `context` avoids a second root inspection and repeated
per-field execution-scope lookups while preserving all public-nominal/member
visibility, active-record cycle, nesting-depth (128), custom-hook dispatch, and
2 GiB message-size checks. `register_resource_codec` registers a state-local
nominal resource capability (used for `thread.Sender` and `thread.Receiver`)
keyed by the record's canonical erased metatable identity, and
`write_resource_index_bytes` / `write_resource_index` write its four-byte
little-endian packet-local slot index. These internal-purpose entries do not
introduce a new standalone serialization policy or make unsupported roots
transferable.

The `context` argument is an explicit capability: a packet transport passes the
`ResourceScope` it already resolved for that packet.
`serialize_fields_to_buffer_with_context`,
`deserialize_fields_buffer_with_context`, and
`deserialize_nominal_buffer_with_context` use the value they are given and never
fall back to the execution's current scope, so `nil` carries no resource
authority. A `thread.Sender` or `thread.Receiver` field encoded or decoded with
`nil` raises `transfer: resource attachment requires an encode scope` or
`transfer: resource claim requires a decode scope`, even when the call runs
inside a `to_transfer_payload` or `from_transfer_payload` hook whose packet
scope is active. The public `serialize_fields_to_buffer`,
`deserialize_fields_buffer`, and `deserialize_nominal_buffer` wrappers resolve
the exact top scope of the current execution in the matching direction once
(`nil` when there is none, as in a standalone call) and delegate. The two
`serialize_inspected_*_to_buffer` entries differ deliberately: given `nil`, they
substitute that same current-execution encode scope, so `serialize_to_buffer`,
which passes no context, can attach endpoints only inside an active packet
encode scope.

The serialized result of `serialize` and `serialize_fields` is a binary string.
Names, filenames, and schemas are ordinary strings too, but wire bytes need not
be text and may contain NULs. Errors are strings identifying the rejected type,
value, or wire condition.

## Anonymous messages

`serialize_fields` and `deserialize_fields` use an explicit ordered Array of
field types instead of a nominal root. Keep the same descriptor beside both
operations; the packet carries values, not the descriptor. This is useful for
custom transfer hooks whose byte payload is an implementation detail:

```titan
local protobuf = import "protobuf"
local reflect = import "reflect"

local const payload_fields: const {reflect.Type} = {
  reflect.Type.is_integer(),
  reflect.Type.is_string(),
}

function encode_payload(handle: integer, buffered: string): string
  return protobuf.serialize_fields(payload_fields, handle, buffered)
end

function decode_payload(bytes: string): (integer, string)
  return protobuf.deserialize_fields(bytes, payload_fields)
end
```

Encoding requires exactly one argument per declared field, including explicit
nil arguments. Decoding returns exactly that many values, preserving interior
and trailing nil positions. An empty descriptor encodes an empty message and
decodes to no values. Field numbers follow descriptor order and use the same
reserved-number skip, presence, merge, wire-validation, nesting, and size rules
as nominal messages. The same fields in a record produce the same wire bytes.

The caller selects field values explicitly; this path does not inspect or
construct a record. Nested records and unions still require public declarations
and public members. Pointer fields use
`reflect.Type.is_foreign_pointer(reflect.Type.is_foreign_void(), {})` and retain
the same borrowed-address semantics as nominal pointer fields. No extra public
record type is needed to define an anonymous root.

## Eligible values

Every encountered Titan nominal type must be public and have only public
fields or variants. A local record or union is rejected even if all its
members are public. Const fields are supported: reconstruction initializes a
new value rather than assigning an existing field.

Eligible field and payload types are:

- Nil, booleans, integers, floats, and byte strings.
- Options of eligible values.
- Public records and unions whose encountered data meets these rules.
- Mutable, const, or maybe-const Titan Arrays of eligible elements.
- Foreign integer and floating scalars, object and function pointers, complete embedded C
  structs, and fixed embedded C arrays, recursively containing eligible data.

The module rejects declared `value`, Maps, Interfaces, Titan/Lua callables, owned foreign
resources, C unions, incomplete aggregates, and flexible arrays. An erased
generic field has its erased descriptor; a runtime value does not restore the
missing generic schema. Foreign C exportability and declaration visibility
also follow the [FFI contract](ffi.md).

Encoding visits the actual graph without a preliminary schema walk. Unsupported
data fails when encountered. For example, an absent optional field or an empty
Array does not require visiting a value of its element type. `schema` traverses
the declared types and can reject a type whose particular value encoded
successfully.

Cycles through records, unions, and Arrays raise. Repeated references in an
acyclic graph are copied independently: decoding does not preserve aliasing.
Pointers copy their numeric addresses without following them, retaining their
targets, or extending their lifetimes. The caller owns pointee lifetime and
synchronization across states.

## Wire mapping

Record fields use declaration order, starting at field number 1. Union variants
use their public ordinal and each variant is a `oneof` member containing a
message of its ordered payload parts. Empty variants have an empty payload
message. Field numbering skips protobuf's reserved interval 19000–19999.

| Titan value | Proto3 representation |
| --- | --- |
| `boolean` | `optional bool` |
| `integer` | `optional sint64`, ZigZag encoded |
| `float` | `optional double` |
| `string` | `optional bytes`, without UTF-8 validation |
| Foreign signed/unsigned integer | `optional sint64` / `optional uint64`, with declared-width checks |
| Foreign `float` / `double` | `optional float` / `optional double` |
| Foreign `long double` | `optional bytes` carrying the exact C hexadecimal floating representation |
| Foreign object or function pointer | `optional fixed64` address |
| Record or embedded C struct | Nested message |
| Union | Nested message with a `oneof` of variant payload messages |
| Titan Array or embedded C array | Nested message with repeated element-slot messages |

An Array slot is a message containing its value at field 1. An empty slot
represents nil, preserving interior holes without shifting subsequent elements.
An empty Array is distinct from an absent optional Array. Titan Array wrappers
also carry constness at field 2; maybe-const reconstruction preserves the
observed qualifier. Fixed C array reconstruction checks the actual target
extent. As elsewhere in Titan, trailing absent elements do not add observable
Array length.

Absent options and nil fields emit no field. Other scalars are emitted even
when equal to protobuf defaults. Decoding requires present non-optional fields
instead of inventing default values for a Titan constructor. Generated schemas
use proto3 optional scalar presence so an external encoder can express this
distinction. A nil field has an empty-message schema and is normally absent.

Schema identifiers escape underscores and punctuation in nominal and field
names; qualified names therefore remain distinct. The returned string includes
`syntax = "proto3";` and all referenced message declarations. Declaration order
is deterministic. Field numbers are tied to Titan declaration order, so changing
that order changes the wire contract; the module is not a schema-versioning
system.

Unknown fields are skipped. Repeated scalar fields take their last value;
repeated singular messages merge, including Array slot sequences. A later
different union variant replaces the previous variant. Malformed tags, varints,
lengths, groups, wire kinds, out-of-range native integers, missing required
fields, and unrecognized union selections raise. Nesting is limited to 128
levels, and messages must fit the protobuf 2 GiB size bound.

Extended C floating values use C hexadecimal text to avoid narrowing to Titan
`float`; they do not acquire a standard protobuf numeric interpretation. Pointer
values are meaningful only while their native targets remain valid in the
receiving process. Native declarations and compatible target layouts remain
the ordinary C FFI precondition.

## Independent states

`transfer.TransferValue.is_record(module, name, bytes)` and
`is_union(module, name, bytes)` (`async.TransferValue` is a transparent alias)
carry the defining module, root type name, and
wire payload. Independent-state calls automatically
serialize eligible returned records and unions; an explicitly returned
`TransferValue` takes precedence over this classification. Receiver messages
copy the module, nominal name, and wire bytes into native packets. Their
[lossy, coalescing delivery](async-io.md#cross-state-receivers) can replace an
unread packet; protobuf encoding adds no delivery guarantee.

`TransferValue:to_value()` first checks the destination nominal registry. On a
miss it calls the recorded module's native preload loader and retries lookup.
The standalone `protobuf.deserialize_nominal` helper only looks up an already
initialized type. See [independent Lua states](standard-library-lua.md) and
[transfer values](async-io.md#transfer-values) for ownership and preload rules.

### Custom record transfer hooks

Records with the [custom transfer-hook pair](async-io.md#custom-record-transfer)
use an `is_record_payload(module, name, bytes)` carrier instead during automatic
transfer at the root. When such a record appears as a nested field inside an
outer public record or union (or inside an Array field), `protobuf.serialize`,
`protobuf.deserialize`, and `protobuf.schema` represent it on the wire as
`optional bytes` without requiring public fields on the hooked record.
Registered packet-scoped resource records (`thread.Sender<|T|>` and
`thread.Receiver<|T|>`) use their transfer-registered `ResourceCodec`
capability to attach and claim the four-byte little-endian slot index directly
in the packet buffer without reflective hook calls or intermediate four-byte
Lua strings (and `TransferValue.from_value` / `:to_value` likewise dispatch
registered `ResourceCodec` records before reflective hooks); other hooked
records delegate to `to_transfer_payload(): string` and
`from_transfer_payload(payload: string): Record`. Hooks may use an
anonymous-message descriptor to encode native tokens and copied state. Calling
`protobuf.serialize` directly on a root record continues to apply the
structural public-data rules in this chapter.

Standalone protobuf operations open no packet resource scope. Neither direct
`ResourceCodec` fields nor `to_transfer_payload` / `from_transfer_payload`
hooks invoked from standalone `protobuf.serialize`, `protobuf.deserialize`, or
`protobuf.deserialize_nominal_buffer` authorize `thread.Sender` or
`thread.Receiver` attachment or claim; they raise unless the work belongs to
the exact current packet scope opened by a
[packet transfer operation](standard-library-transfer.md#scoped-resource-attachments-and-packet-local-indexes).
Hooks remain synchronous and nonyielding; nested hook dispatch does not change
their ownership or execution contract.
