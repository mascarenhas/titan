# Protocol Buffers standard library

Import `protobuf` in Titan, or require `titan.protobuf` in Lua. The module copies
public record and union values using the [Protocol Buffers wire
format](https://protobuf.dev/programming-guides/encoding/). It also emits the
matching proto3 schema. The declared types determine the wire format, and
decoding constructs fresh values field by field without calling a user-defined
`new`.

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
deserialize_nominal(bytes: string, name: string, is_union: boolean): value
schema(descriptor: reflect.Type): string
serialize_fields(fields: const {reflect.Type}, ...: value): string
deserialize_fields(bytes: string, fields: const {reflect.Type}): (...: value)

record PortableCodec  -- private state
portable(fields: const {reflect.Type},
         dynamic: const {reflect.Type}?): PortableCodec
PortableCodec:encode(...: value): string
PortableCodec:decode(bytes: string): (...: value)

serialize_to_buffer(buf: foreign *void, candidate: value)
serialize_fields_to_buffer(buf: foreign *void,
                           fields: const {reflect.Type}, ...: value)
deserialize_nominal_buffer(data: foreign const *void, length: integer,
                           name: string, is_union: boolean): value
deserialize_fields_buffer(data: foreign const *void, length: integer,
                          fields: const {reflect.Type}): (...: value)

use_generated_codecs(enabled: boolean): boolean
```

The root must be a public Titan record or union. `deserialize` and `schema`
accept its record/union descriptor or a named descriptor that resolves to it.
`deserialize_nominal` performs the same operation using a fully qualified name,
and checks the requested nominal kind. It is also the independent-state
argument conversion entry. Unknown names raise; lookup does not load modules.
When a root fails several checks, decoding reports the first of: an unknown
name or unresolvable descriptor, a root of the wrong kind, a message larger
than 2 GiB, and a root that is local or has private members.

`serialize_to_buffer` and `serialize_fields_to_buffer` append wire bytes to a
caller-initialized `titan_protobuf_buffer` (`buf`) without building a Lua
string. The caller owns the buffer, keeps it and whatever its `context` field
refers to valid until the call returns, and afterwards frees or detaches the
storage with the matching native buffer operations. The buffer's `grow`
callback may run synchronously during an append and must provide at least the
capacity it is asked for. The capacities requested are not part of the
contract; the
[implementation chapter](../implementation/protobuf-library.md#encoding)
describes the current growth policy. `deserialize_nominal_buffer` and
`deserialize_fields_buffer` decode from the borrowed byte range of `length`
bytes at `data`.

The serialized result of `serialize` and `serialize_fields` is a binary string.
Names, filenames, and schemas are ordinary strings too, but wire bytes need not
be text and may contain NULs. Errors are strings identifying the rejected type,
value, or wire condition.

### Transfer collaboration entries

`titan.transfer` shares protobuf's codec with its packets through the
following public declarations. They are compiled collaboration entries, not an
application API: they add no serialization policy and make no unsupported root
transferable.

```text
find_transfer_hooks(descriptor: reflect.RecordType, prefix: string):
    (reflect.MethodType?, reflect.StaticFunctionType?)
encode_transfer_payload(candidate: value, encode: reflect.MethodType,
                        err_msg: string): string
serialize_inspected_record_to_buffer(buf: foreign *void,
                                     candidate: reflect.RecordValue,
                                     context: value)
serialize_inspected_union_to_buffer(buf: foreign *void,
                                    candidate: reflect.UnionValue,
                                    context: value)
serialize_fields_to_buffer_with_context(buf: foreign *void,
                                        fields: const {reflect.Type},
                                        context: value, ...: value)
deserialize_fields_buffer_with_context(data: foreign const *void,
                                       length: integer,
                                       fields: const {reflect.Type},
                                       context: value): (...: value)
deserialize_nominal_buffer_with_context(data: foreign const *void,
                                        length: integer,
                                        nominal: reflect.NominalType?,
                                        name: string, is_union: boolean,
                                        context: value): value
find_generated_codec(candidate: value): foreign const *void
serialize_generated_to_buffer(buf: foreign *void, codec: foreign const *void,
                              candidate: value, context: value): boolean

record ResourceCodec
  const identity: value
  const descriptor: reflect.RecordType
  const encode: function (value, value): (integer)
  const decode: function (value, foreign const *void, integer): (value)
end
register_resource_codec(
    candidate: value, descriptor: reflect.RecordType,
    encode: function (value, value): (integer),
    decode: function (value, foreign const *void, integer): (value))
find_resource_codec(candidate: value): ResourceCodec?
find_resource_codec_by_name(name: string): ResourceCodec?
foreign function write_resource_index_bytes(dst: *void, index: unsigned int)
foreign function write_resource_index(raw_buf: *void, index: unsigned int): int
set_packet_context_provider(provider: function (boolean): (value))
set_nominal_loader(loader: function (string, string): ())
```

- `find_transfer_hooks` returns a record's validated `to_transfer_payload`
  method and `from_transfer_payload` static function, or `(nil, nil)` when the
  record defines neither; `prefix` (`"protobuf"` or `"transfer"`) only labels
  validation errors. `encode_transfer_payload` calls that method under the
  shared active-record cycle guard and raises `err_msg` if `candidate` is
  already being encoded.
- The `serialize_inspected_*` entries append a root, already inspected by the
  caller, to a live, initialized buffer that they neither own nor free. All
  visibility, cycle, nesting-depth, hook, and size checks still apply.
- `context` is the packet scope that the transport has already resolved. It is
  valid only during the call that receives it, including a `ResourceCodec`
  `encode` or `decode` call; never keep it for later use. The three
  `*_with_context` entries use exactly the context they are given, so `nil`
  grants no resource authority, even inside a hook whose packet is
  active: a `thread.Sender` or `thread.Receiver` field then raises
  `"transfer: resource attachment requires an encode scope"` or
  `"transfer: resource claim requires a decode scope"`. Given `nil`, the
  `serialize_inspected_*` entries and `serialize_generated_to_buffer` instead
  use the current execution's encode scope, if any, as `serialize_to_buffer`
  does. `deserialize_nominal_buffer_with_context` takes the caller's
  `reflect.find_nominal(name)` result as `nominal` and raises the same
  unknown-name and kind-mismatch errors as `deserialize_nominal_buffer`, using
  `name` only in those messages.
- `find_generated_codec` returns the [generated codec](#generated-codecs) of a
  nominal instance, or nil when the reflective codec handles it.
  `serialize_generated_to_buffer` appends that root with the given codec, or
  returns false and appends nothing when `codec` is not the value's codec.
- `register_resource_codec` registers a packet-scoped resource record type for
  the current Lua state (in the standard library, `thread.Sender` and
  `thread.Receiver`). The registration is keyed by the record's erased type, so
  it covers every application of a generic record. `find_resource_codec` and
  `find_resource_codec_by_name` look it up by instance or by qualified name.
  `write_resource_index_bytes` and `write_resource_index` write a four-byte
  little-endian packet-local slot index to raw memory or to a buffer.
- `set_packet_context_provider` and `set_nominal_loader` install
  `titan.transfer`'s scope lookup and module loader in the current state.

## Generated codecs

The compiler generates a native encoder and decoder for each public record or
union whose members are all public, whose fields all have types this module can
encode (so no callables, Maps, Interfaces, or owned or union C types), and that
has no custom transfer hooks. Wide declarations stay reflective: a record with
more than 64 fields, or a union with a variant of more than 63 parts; the
number of variants does not matter. Every protobuf and transfer operation uses
a generated codec wherever it meets such a nominal, as the root or nested in
another value. Generated codecs produce exactly the bytes, values, errors, hook
calls, and resource attachments described in this chapter; only their cost
differs. Fields that a generated codec does not handle natively—Arrays, foreign
values, records with hooks, `thread` endpoints, and `value` fields holding
nominals or Arrays—use the reflective codec for that field. The
[implementation chapter](../implementation/protobuf-library.md#generated-nominal-codecs)
describes the allocation profile.

`use_generated_codecs(false)` makes later codec lookups in the current Lua
state choose the reflective codec, and returns the previous setting. It is a
diagnostic for comparing the two codecs and changes no observable result.
Codec handles obtained before the call still run generated code when passed to
`serialize_generated_to_buffer`.

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

## Portable codecs

`portable` creates a reusable codec for copied data shared by native and browser
targets. Its ordered `fields` describe an anonymous root, just as for
`serialize_fields`. Creation checks the complete public type graph before
visiting any values, even for absent Options, empty Arrays, and inactive public
union variants.

| Declared type | Portable policy |
| --- | --- |
| Nil, boolean, integer, float, string, `value` | Accepted |
| Option or mutable, const, maybe-const Array | Accepted when its element is portable |
| Public record | Accepted when every public field type is portable |
| Public union | Accepted when every public variant's parts are portable |
| Record with transfer hooks, or a packet resource | Rejected |
| Local nominal | Rejected |
| Map, Interface, callable, or any foreign type | Rejected |

The codec closes over every record and union reachable through `fields` and the
optional `dynamic` Array. Each `dynamic` entry must resolve to a record or
union. A `value` position may contain the supported scalars, Arrays, and only
those nominals in this closed set; include additional nominal descriptors in
`dynamic` when they occur only inside `value` positions. Unknown or unlisted
names raise `protobuf: <name> is not in this portable codec`. Decoding never
loads modules on demand, calls transfer hooks, or attaches or claims packet
resources. A `transfer.TransferValue` is not a portable type because some of
its declared variants contain foreign values.

`codec:encode(...)` requires exactly one argument per field, including nil
positions. `codec:decode(bytes)` returns exactly that many results. The
ordinary protobuf wire validation, graph-cycle rejection, nesting bound, Array
holes, and constness rules apply. Repeated acyclic references are copied
independently. The codec retains its input string during decoding and returns
independent values, not views into the input bytes.

For values accepted by both entries, portable encoding is byte-for-byte
identical to `serialize_fields(fields, ...)`. Public views also use the
ordinary field framing; plain protobuf entries retain their stricter
visibility checks.

### Public views and construction

A public record with local fields crosses as its public fields, in declaration
order; local storage is not serialized. Decoding uses a compatible public
`new`, found by [`RecordType:public_constructor()`](standard-library-reflect.md#public-nominal-members).
Every fixed constructor parameter must be named after a public field. Each
field is decoded and validated against its declared field type, and the
same-named values are passed in constructor parameter order, preserving nil
positions. Public fields not taken by the constructor are validated and
dropped. Constructor errors propagate.

Without such a constructor, the record is encode-only: decoding raises
`protobuf: <name> has no public constructor over its public fields` before
constructing that record. All-public records instead retain ordinary protobuf
construction: fields are initialized directly, without invoking `new`.

A public union may have private variants. A public active arm crosses normally;
encoding a private active arm raises `protobuf: private union variant`.
Decoding an ordinal with no recognized public variant raises.

Creation errors identify the descriptor path and rejected kind or nominal.
Paths use JSON's syntax: `$[1]` selects the first root field,
`$[1]["items"][1]` its Array element schema, and
`$["dynamic"][2]` the second additional nominal. Options add no path component;
an Array element schema uses the representative index 1. Field and part names
are quoted. For example, a hooked record reports
`protobuf: $[1]: <name> has transfer hooks`, and a resource reports
`protobuf: $[1]: <name> is a packet resource and is not portable`.

## Eligible values

For ordinary protobuf entries, every encountered Titan nominal type must be
public and have only public fields or variants. A local record or union is
rejected even if all its members are public. Const fields are supported:
reconstruction initializes a new value rather than assigning an existing
field. [Portable codecs](#portable-codecs) instead accept the public views
described above.

Eligible field and payload types are:

- Nil, booleans, integers, floats, and byte strings.
- Options of eligible values.
- Public records and unions whose encountered data meets these rules.
- Mutable, const, or maybe-const Titan Arrays of eligible elements.
- `value` fields and parts, including erased generic parameters, holding nil,
  a boolean, integer, float, or string, a public record or union whose
  encountered data meets these rules, or a Titan Array of such values.
- Foreign integer and floating scalars, object and function pointers, complete embedded C
  structs, and fixed embedded C arrays, recursively containing eligible data.

The module rejects Maps, Interfaces, Titan/Lua callables, owned foreign
resources, C unions, incomplete aggregates, and flexible arrays. A `value`
holding a Map, a callable, a raw pointer, or another unsupported kind raises
`protobuf: unsupported dynamic value`. Foreign C exportability and declaration
visibility also follow the [FFI contract](ffi.md).

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
| `value` | Nested `TitanValue` message with a `oneof` (below); absent when nil |

An Array slot is a message containing its value at field 1. An empty slot
represents nil, preserving interior holes without shifting subsequent elements.
An empty Array is distinct from an absent optional Array. Titan Array wrappers
also carry constness at field 2; maybe-const reconstruction preserves the
observed qualifier. Fixed C array reconstruction checks the actual target
extent. As elsewhere in Titan, trailing absent elements do not add observable
Array length.

A `value` field is self-describing. Its `TitanValue` message holds one `oneof`
arm: `bool boolean = 1`, `sint64 integer = 2`, `double number = 3`,
`bytes string = 4`, `TitanValue_Nominal nominal = 5`, or a Titan Array of
`TitanValue` elements at 6. The nominal arm carries the declaring module name
at field 1, the qualified nominal name at field 2, and at field 3 the bytes that
a field of that nominal type carries: its message, its custom hook payload, or
its packet resource index. Decoding uses the last recognized arm and treats a
message with none as nil; a decoded Array keeps the constness it was encoded
with.

A nominal named inside a `value` field must already be initialized in the
decoding state, or decoding raises `protobuf: unknown nominal type`. The one
exception is decoding a transfer packet, which loads the declaring module on
demand. `TransferValue:to_value` outside a packet therefore loads the root
nominal's module but not a module named only inside a `value` field.

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
fields, and unrecognized union selections raise. Messages must fit the
protobuf 2 GiB size bound.

Nesting is limited on every encoding, decoding, and schema path, generated or
reflective. Levels count nested messages and the fields of the innermost one:
a chain of records whose innermost record has a field holds at most 127 records
on native and browser targets. Deeper input raises the ordinary catchable
error `protobuf: nesting exceeds 128 levels`. This bounds the codec's own
traversal, not stack already used by its caller.

String entry points keep their input alive throughout decoding, including
while a custom decoder runs after the caller has dropped its last reference to
it. The raw `*_buffer` entry points borrow caller-owned memory: keep the
complete byte range alive and unchanged until the synchronous call returns or
raises, including while a custom decoder runs. A raw pointer does not retain a
Titan string or native allocation. Decoded byte fields are independent strings,
not views of the input.

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

During automatic transfer, a root record with the
[custom transfer-hook pair](async-io.md#custom-record-transfer) travels as an
`is_record_payload(module, name, bytes)` carrier. When such a record is a field,
variant part, or Array element inside another public record or union,
`protobuf.serialize`, `protobuf.deserialize`, and `protobuf.schema` represent
it as `optional bytes` holding its hook payload, and its own fields need not be
public. `thread.Sender` and `thread.Receiver` fields use the same
representation, but their payload is a four-byte packet-local slot index that
`titan.transfer` writes and claims directly, without calling their hooks. Hooks
may use an anonymous-message descriptor to encode native tokens and copied
state. Calling `protobuf.serialize` on a hooked record as the root still
applies the structural public-data rules of this chapter.

Standalone protobuf calls open no packet scope. When `protobuf.serialize`,
`protobuf.deserialize`, or `protobuf.deserialize_nominal_buffer` meets a
`thread.Sender` or `thread.Receiver` field, or a hook that attaches or claims
one, it raises unless the call runs inside the current execution's matching
scope, opened by a
[packet transfer operation](standard-library-transfer.md#scoped-resource-attachments-and-packet-local-indexes).
Hooks remain synchronous and nonyielding, including when called for nested
fields.
