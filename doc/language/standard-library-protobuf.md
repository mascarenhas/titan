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
deserialize(bytes: string, descriptor: reflect.Type): value
schema(descriptor: reflect.Type): string
deserialize_nominal(bytes: string, name: string, is_union: boolean): value
serialize_fields(fields: const {reflect.Type}, ...: value): string
deserialize_fields(bytes: string, fields: const {reflect.Type}): (...: value)
```

The root must be a public Titan record or union. `deserialize` and `schema`
accept its record/union descriptor or a named descriptor that resolves to it.
`deserialize_nominal` performs the same operation using a fully qualified name,
and checks the requested nominal kind. It is also the independent-state
argument conversion entry. Unknown names raise; lookup does not load modules.

The serialized result is a binary string. Names, filenames, and schemas are
ordinary strings too, but wire bytes need not be text and may contain NULs.
Errors are strings identifying the rejected type, value, or wire condition.

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

`async.TransferValue.is_record(module, name, bytes)` and
`is_union(module, name, bytes)` carry the defining module, root type name, and
wire payload. Independent-state calls automatically
serialize eligible returned records and unions; an explicitly returned
`TransferValue` takes precedence over this classification. Receiver messages
copy the module, nominal name, and wire bytes into native packets. Their
[lossy, coalescing delivery](async-io.md#cross-state-receivers) can replace an
unread packet; protobuf encoding adds no delivery guarantee.

Records with the [custom transfer-hook pair](async-io.md#custom-record-transfer)
use an `is_record_payload(module, name, bytes)` carrier instead during automatic
transfer. Hooks may use an anonymous-message descriptor to encode native
tokens and copied state. Calling `protobuf.serialize` directly
continues to apply the structural public-data rules in this chapter.

`TransferValue:to_value()` first checks the destination nominal registry. On a
miss it calls the recorded module's native preload loader and retries lookup.
The standalone `protobuf.deserialize_nominal` helper only looks up an already
initialized type. See [independent Lua states](standard-library-lua.md) and
[transfer values](async-io.md#transfer-values) for ownership and preload rules.
