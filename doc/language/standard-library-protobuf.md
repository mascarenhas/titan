# Protocol Buffers standard library

`titan.protobuf` serializes and deserializes public Titan records and tagged
unions in the [Protocol Buffers wire
format](https://protobuf.dev/programming-guides/encoding/), emits matching
proto3 schemas, and builds target-neutral portable codecs. Declared field order
determines wire tags, and ordinary decoding constructs values directly without
calling user-defined `new`.

- **Import:** `local protobuf = import "protobuf"` (Titan) · `require "titan.protobuf"` (Lua)
- **Targets:** Native & Browser (complete; synchronous)

## Quick examples

Serialize a record and union to binary wire bytes, decode them back via a
reflection descriptor, and inspect the generated proto3 schema. Save this
program as `pb_example.titan`:

```titan
local protobuf = import "protobuf"
local reflect = import "reflect"
local io = import "io"

record Note
  const sequence: integer
  text: string
end

union Event
  note(Note)
  ping(seq: integer)
end

function main(_args: {string}): integer
  local original = Event.note(Note(7, "hello\0world"))
  local bytes = protobuf.serialize(original)

  local target = reflect.Type.is_named(reflect.NamedType("pb_example.Event"))
  local restored: Event = protobuf.deserialize(bytes, target)
  case restored
  when note(n) then
    io.print(n.sequence, #n.text)
  when ping(seq) then
    io.print("ping", seq)
  end

  io.print(protobuf.schema(target))
  return 0
end
```

For data shared across native and browser targets (including JavaScript peers),
create a reusable `PortableCodec` with `protobuf.portable`. Save this program as
`pb_portable.titan`:

```titan
local protobuf = import "protobuf"
local reflect = import "reflect"
local io = import "io"

record Reading
  sensor: string
  celsius: float
end

function main(_args: {string}): integer
  local fields: const {reflect.Type} = {
    reflect.Type.is_named(reflect.NamedType("pb_portable.Reading")),
    reflect.Type.is_string(),
  }
  local text_paths: const {string} = { "2", "pb_portable.Reading.sensor" }
  local codec = protobuf.portable(fields, nil, text_paths)

  local wire = codec:encode(Reading("roof", 21.5), "ok")
  local reading: Reading, status: string = codec:decode(wire)
  io.print(reading.sensor, reading.celsius, status)
  io.print(codec:describe())
  return 0
end
```

## API

```text
function serialize(candidate: value): string
function deserialize(bytes: string, descriptor: reflect.Type): value
function deserialize_nominal(bytes: string, name: string, is_union: boolean): value
function schema(descriptor: reflect.Type): string
```

The root of `serialize`, `deserialize`, `deserialize_nominal`, and `schema` must
be a public Titan record or union whose members are all public. `deserialize`
and `schema` accept a record/union descriptor or a `NamedType` descriptor that
resolves to one. `deserialize_nominal` looks up a fully qualified name directly
and checks whether it matches `is_union`; lookup does not import modules and
raises for unknown names. When a root fails multiple checks, decoding reports
the first of: an unknown or unresolvable type, a kind mismatch, a message over
2 GiB, and a local or partially private nominal.

Wire bytes returned by `serialize` are ordinary Titan binary strings and may
contain embedded NULs. Codec failures raise error strings identifying the
rejected type, value, or wire condition.

### Buffer entry points

```text
function serialize_to_buffer(buf: foreign *void, candidate: value)
function serialize_fields_to_buffer(buf: foreign *void,
                                    fields: const {reflect.Type}, ...: value)
function deserialize_nominal_buffer(data: foreign const *void, length: integer,
                                    name: string, is_union: boolean): value
function deserialize_fields_buffer(data: foreign const *void, length: integer,
                                   fields: const {reflect.Type}): (...: value)
```

The `*_to_buffer` functions append wire bytes directly to a caller-initialized
`titan_protobuf_buffer` (`buf`) without allocating a Lua string. The caller owns
the buffer and its `context` until the call returns, and frees or detaches the
storage afterward. Its `grow` callback may run synchronously during an append
and must supply at least the requested capacity. The `deserialize_*_buffer`
functions decode from a caller-owned byte range of `length` bytes at `data`,
which must stay alive and unchanged until the call returns or raises.

### Errors

Nested encoding and decoding failures can end with ` at <path>`, using the same
path syntax as [`json.Error.path`](standard-library-json.md#diagnostics-and-limits):
`$` for the root, `["name"]` for record fields or union parts, and `[n]` for
1-based Array elements or anonymous root fields (`value` slots add no segment):

```text
protobuf: missing required field 2 at $["items"][3]["label"]
protobuf: unsupported dynamic value at $[1]["payload"]
```

For nested encoding or decoding failures, Titan attaches ` at <path>` without
re-invoking transfer hooks, resource callbacks, `new`, or module loaders; root,
schema, hook-validation, and registration errors are reported directly.
Generated codecs report up to 16 nesting levels before abbreviating deeper paths
with `...`; reflective traversal reports full paths.

The `"protobuf: "` prefix is reserved for codec diagnostics. User callbacks that
raise errors without that prefix (or raise non-string values) propagate
unchanged.

## Eligible values

Ordinary protobuf operations require every encountered nominal type to be public
and to have only public fields or variants. Const fields are supported because
decoding initializes fresh values directly.

Eligible field and payload types:

- `nil`, `boolean`, `integer`, `float`, and byte `string`.
- Options of eligible types.
- Public records and unions whose encountered values satisfy these rules.
- Mutable, `const`, and `const?` Titan Arrays of eligible elements.
- `value` slots (including erased generic parameters) holding `nil`, scalars,
  public records or unions, or Titan Arrays of eligible values.
- Foreign integer and float scalars, object and function pointers, complete
  embedded C structs, and fixed embedded C arrays containing eligible data.

Maps, Interfaces, Titan and Lua callables, owned foreign storage, C unions,
incomplete C aggregates, and flexible C arrays are rejected. A `value` holding
an unsupported kind raises `protobuf: unsupported dynamic value`. Foreign C
visibility follows the [FFI rules](ffi.md).

`serialize` inspects the runtime value graph lazily, so an absent Option or
empty Array does not fail even if its declared element type is unsupported;
`schema` walks declared types eagerly and rejects unsupported declarations.
Cycles through records, unions, and Arrays raise. Shared acyclic references are
copied independently. Foreign pointers copy their numeric address only; the
caller owns pointee lifetime and synchronization.

## Wire mapping

Record fields take declaration order starting at field number 1. Union variants
use their public ordinal inside a `oneof` of variant payload messages (empty
variants carry an empty message). Field numbering skips protobuf's reserved
range 19000–19999.

| Titan type | Proto3 representation |
| --- | --- |
| `boolean` | `optional bool` |
| `integer` | `optional sint64` (ZigZag encoded) |
| `float` | `optional double` |
| `string` | `optional bytes` (no UTF-8 validation) |
| Foreign signed / unsigned integer | `optional sint64` / `optional uint64` (width checked) |
| Foreign `float` / `double` | `optional float` / `optional double` |
| Foreign `long double` | `optional bytes` (exact C hexadecimal float text) |
| Foreign object or function pointer | `optional fixed64` address |
| Record or embedded C struct | Nested message |
| Union | Nested message with `oneof` variant messages |
| Titan Array or fixed C array | Nested message with repeated element-slot messages |
| `value` | Nested `TitanValue` message (absent when `nil`) |

Array elements are wrapped in slot messages carrying their element at field 1;
an empty slot preserves an interior `nil` hole without shifting later indices.
An empty Array is distinct from an absent optional Array, and trailing absent
elements do not extend `#array`. Titan Array wrappers also store constness at
field 2, which `const?` targets preserve on decode. Fixed C arrays verify exact
length on decode.

`value` fields use a self-describing `TitanValue` message with one `oneof`:
`bool boolean = 1`, `sint64 integer = 2`, `double number = 3`,
`bytes string = 4`, `TitanValue_Nominal nominal = 5`, or an Array of
`TitanValue` at field 6. `TitanValue_Nominal` carries the declaring module name
at field 1, the qualified nominal name at field 2, and the nominal's wire bytes
at field 3. Decoding takes the last recognized arm and treats an empty message
as `nil`. Nominals inside `value` must already be initialized in the receiving
state (except during cross-state transfer packets, which preload declaring
modules on demand).

Absent options and `nil` fields emit no wire bytes. Present scalars always emit,
even for protobuf zero defaults, and decoding requires every non-optional field
to be present. `schema` emits `syntax = "proto3";` with `optional` scalar
presence and deterministic declaration order, escaping punctuation in qualified
names. Field numbers follow Titan declaration order, so reordering fields
changes the wire format.

Decoding skips unknown fields, takes the last repeated scalar, merges repeated
singular messages (including Array slot sequences), and replaces earlier union
variants with later ones. Malformed wire framing, groups, wrong wire types,
out-of-range integers, missing required fields, unrecognized union tags, and
messages above 2 GiB raise.

Nesting depth is bounded at 128 levels across encoding, decoding, and `schema`
on both native and browser targets (127 chained records under a nominal root, or
126 under an anonymous root field). Deeper graphs raise
`protobuf: nesting exceeds 128 levels`. String entry points retain their input
string throughout decoding, and decoded byte fields are independent strings.

## Anonymous messages

```text
function serialize_fields(fields: const {reflect.Type}, ...: value): string
function deserialize_fields(bytes: string, fields: const {reflect.Type}): (...: value)
```

`serialize_fields` and `deserialize_fields` encode and decode an ordered tuple
described by `fields` without declaring a wrapper record. Both sides must supply
the same field descriptor list:

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

Encoding requires one argument per declared field (including explicit `nil`s),
and decoding returns that exact count while preserving interior and trailing
`nil`s. An empty descriptor list encodes `""` and decodes to zero values. Field
numbering, presence, merge, nesting, and size rules match a record with the same
fields. Raw pointer fields use
`reflect.Type.is_foreign_pointer(reflect.Type.is_foreign_void(), {})`.

## Portable codecs

```text
record PortableCodec

function portable(fields: const {reflect.Type},
                  dynamic: (const {reflect.Type})?,
                  text: (const {string})?): PortableCodec
function PortableCodec:encode(...: value): string
function PortableCodec:decode(bytes: string): (...: value)
function PortableCodec:describe(): string
```

`portable` validates the entire reachable public type graph upfront—including
absent Options, empty Arrays, and inactive union arms—and builds a reusable
codec for pure copied data across native and browser targets.

| Declared type | Portable policy |
| --- | --- |
| `nil`, `boolean`, `integer`, `float`, `string`, `value` | Accepted |
| Option or mutable / `const` / `const?` Array | Accepted if element is portable |
| Public record | Accepted if every public field is portable |
| Public union | Accepted if every public variant part is portable |
| Record with transfer hooks or packet resource | Rejected |
| Local nominal | Rejected |
| Map, Interface, callable, or any foreign type | Rejected |

The codec closes over every record and union reachable from `fields` and the
optional `dynamic` list (each `dynamic` entry must resolve to a record or
union). A `value` slot may carry supported scalars, Arrays, and only nominals in
this closed set; any other nominal raises
`protobuf: <name> is not in this portable codec`. Portable codecs never load
modules on demand, run transfer hooks, or attach packet resources. Creation
errors report the offending descriptor path (for example `$[1]`,
`$[1]["items"][1]`, `$["dynamic"][2]`).

`encode` requires one argument per root field and `decode` returns that exact
number of values. For values accepted by both APIs, portable wire bytes are
identical to `serialize_fields`.

### Public views and construction

Under a portable codec, a public record with `local` fields serializes its
public fields in declaration order. Decoding uses a compatible public `new`
found via [`RecordType:public_constructor()`](standard-library-reflect.md#public-nominal-members)
whose fixed parameters are each named after a public field; decoded public
fields are validated and passed in constructor parameter order (unused public
fields are validated and discarded). Without such a constructor, the record is
encode-only and decoding raises
`protobuf: <name> has no public constructor over its public fields`. All-public
records construct fields directly without invoking `new`.

A public union with `local` variants encodes active public arms normally and
raises `protobuf: private union variant` for an active private arm.

### Schema descriptions and text positions

`codec:describe()` returns a deterministic cached JSON schema for external
peers:

```json
{"fields":[["nominal","app.Point"],"value"],"nominals":{"app.Point":{"module":"app","record":[["x","integer"],["label","bytes"]]}}}
```

The object contains `fields` (ordered root descriptors) and `nominals` (sorted
by qualified name). Each nominal entry carries `module` plus either `"record"`
(`[fieldName, T]` pairs) or `"union"` (`[variantName, [[partName, T], ...]]`
pairs, using `"value"` for single unnamed parts). Local fields and private
variants are omitted.

| Type description `T` | Meaning |
| --- | --- |
| `"nil"`, `"boolean"`, `"integer"`, `"float"` | Scalar |
| `"bytes"` | Titan string as raw bytes |
| `"text"` | Titan string marked as UTF-8 text for the peer |
| `"value"` | Self-describing dynamic value |
| `["option", T]` | Optional `T` |
| `["array", constness, T]` | Array (`constness` is `"mutable"`, `"const"`, or `"maybe"`) |
| `["nominal", qualifiedName]` | Entry in `nominals` |

Pass `text` paths to `portable` to mark specific string leaves as `"text"` in
the JSON description: `"<n>"` for 1-based root field `n`,
`"<Nominal>.<field>"` for a record field, or `"<Nominal>.<variant>.<part>"` for
a union part. Paths may traverse Options and Arrays, but must end at a `string`
(not `value`) inside the codec's closed set. Marking affects only `describe()`;
Titan wire encoding and decoding treat strings as raw bytes without UTF-8
checks.

For JavaScript peer classes and error rules, see
[Copying typed values](standard-library-browser.md#copying-typed-values).

## Generated codecs

```text
function use_generated_codecs(enabled: boolean): boolean
```

The compiler generates native encoders and decoders for every all-public record
(up to 64 fields) and all-public union (up to 63 parts per variant) whose fields
are protobuf-eligible and that defines no custom transfer hooks. Every protobuf
and transfer call uses generated codecs automatically, falling back to
reflection only for individual fields they do not handle natively (Arrays,
foreign types, hooked records, `thread` endpoints, and dynamic nominals).

`use_generated_codecs(false)` forces subsequent codec lookups in the current Lua
state to use the reflective path and returns the previous setting, useful for
diagnostic comparisons.

## Independent states and transfer collaboration

`transfer.TransferValue.is_record(module, name, bytes)` and
`is_union(module, name, bytes)` (`async.TransferValue` is a transparent alias)
carry serialized nominals across independent Lua states and threads.
`TransferValue:to_value()` checks the destination registry and, on a miss,
preloads the declaring module before decoding; `protobuf.deserialize_nominal`
only queries already-initialized types. See
[independent Lua states](standard-library-lua.md),
[cross-state receivers](async-io.md#cross-state-receivers), and
[transfer values](async-io.md#transfer-values).

### Custom record transfer hooks

During automatic transfer, a root record with a
[custom transfer-hook pair](async-io.md#custom-record-transfer) travels as
`is_record_payload(module, name, bytes)`. When that record appears nested inside
another public record, union, or Array, `protobuf.serialize`, `deserialize`, and
`schema` encode it as `optional bytes` carrying its hook payload (its own fields
need not be public). `thread.Sender` and `thread.Receiver` fields use the same
wire field to carry a 4-byte packet-local resource index managed by
`titan.transfer`. Calling `protobuf.serialize` directly on a hooked record as
the root applies structural public-data rules instead.

Standalone protobuf calls open no packet scope: encountering a `thread.Sender`
or `thread.Receiver` (or a hook that attaches or claims one) raises unless
running inside an active scope opened by
[`titan.transfer`](standard-library-transfer.md). Hooks must be synchronous and
non-yielding.

### Transfer collaboration entries

`titan.transfer` shares `titan.protobuf`'s codecs through the following public
collaboration entries (they do not extend standalone serialization policy):

```text
record ResourceCodec
  const identity: value
  const descriptor: reflect.RecordType
  const encode: function(value, value): integer
  const decode: function(value, foreign const *void, integer): value
end

function find_transfer_hooks(descriptor: reflect.RecordType,
                             prefix: string): (reflect.MethodType?,
                                               reflect.StaticFunctionType?)
function encode_transfer_payload(candidate: value, encode: reflect.MethodType,
                                 err_msg: string): string
function serialize_inspected_record_to_buffer(buf: foreign *void,
                                              candidate: reflect.RecordValue,
                                              context: value)
function serialize_inspected_union_to_buffer(buf: foreign *void,
                                             candidate: reflect.UnionValue,
                                             context: value)
function serialize_fields_to_buffer_with_context(buf: foreign *void,
                                                 fields: const {reflect.Type},
                                                 context: value, ...: value)
function deserialize_fields_buffer_with_context(data: foreign const *void,
                                                length: integer,
                                                fields: const {reflect.Type},
                                                context: value): (...: value)
function deserialize_nominal_buffer_with_context(data: foreign const *void,
                                                 length: integer,
                                                 nominal: reflect.NominalType?,
                                                 name: string,
                                                 is_union: boolean,
                                                 context: value): value
function find_generated_codec(candidate: value): foreign const *void
function serialize_generated_to_buffer(buf: foreign *void,
                                       codec: foreign const *void,
                                       candidate: value,
                                       context: value): boolean
function register_resource_codec(candidate: value,
                                 descriptor: reflect.RecordType,
                                 encode: function(value, value): integer,
                                 decode: function(value, foreign const *void,
                                                  integer): value)
function find_resource_codec(candidate: value): ResourceCodec?
function find_resource_codec_by_name(name: string): ResourceCodec?
foreign function write_resource_index_bytes(dst: *void, index: unsigned int)
foreign function write_resource_index(raw_buf: *void, index: unsigned int): int
function set_packet_context_provider(provider: function(boolean): value)
function set_nominal_loader(loader: function(string, string))
```

- `find_transfer_hooks` returns validated `to_transfer_payload` and
  `from_transfer_payload` descriptors (or `(nil, nil)`), labeling validation
  errors with `prefix`. `encode_transfer_payload` runs the encode hook under the
  active-record cycle guard and raises `err_msg` on reentry.
- `serialize_inspected_*` append an already-inspected root to a caller-owned
  buffer with all visibility, cycle, nesting, hook, and size checks active.
- `context` is valid only for the duration of the call that receives it. The
  `*_with_context` entries use only the passed `context` (`nil` grants no
  resource scope); `serialize_inspected_*` and `serialize_generated_to_buffer`
  fall back to the current execution's encode scope when `context` is `nil`.
  `deserialize_nominal_buffer_with_context` accepts a pre-looked-up `nominal`
  and uses `name` in diagnostics.
- `find_generated_codec` returns a nominal's generated codec handle or `nil`;
  `serialize_generated_to_buffer` encodes with it or returns `false` if the
  handle does not match `candidate`.
- `register_resource_codec` registers a packet-scoped resource record keyed by
  erased type (`find_resource_codec` and `find_resource_codec_by_name` query
  it). `write_resource_index_bytes` and `write_resource_index` write a 4-byte
  little-endian slot index. `set_packet_context_provider` and
  `set_nominal_loader` install `titan.transfer`'s scope provider and module
  loader for the current state.

See [Protocol Buffers implementation](../implementation/protobuf-library.md) for
encoder growth and generated-codec allocation details.
