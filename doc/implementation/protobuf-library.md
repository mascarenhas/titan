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

## Encoding

The encoder keeps an active-path Map keyed by the original nominal or Array
value. A deferred removal accompanies every entry, so exceptions unwind the
cycle detector. Shared values outside the active path are encoded again. The
encoder does not prevalidate the entire declared type graph; it resolves and
checks descriptors as their values are visited. Union traversal visits the
active payload only; the all-public type flag still rejects private variants
anywhere on that nominal declaration.

All accumulation uses `string.StringWriter`. Varints use logical shifts on the
64-bit integer carrier, including unsigned bit patterns represented by negative
Titan integers. ZigZag preserves the complete signed range. Fixed floating
and pointer payloads use explicitly little-endian `string.pack` formats.
Foreign signedness and width checks run before publication. Structs use member
order; nested fixed arrays use their projected values and target construction
validates the actual C extent without evaluating C expressions in Titan.

Array wrappers retain slot positions and distinguish absence from an empty
container. Nil slots produce empty element messages. The constness field
preserves a maybe-const Array's actual state. Nil/optional omission and explicit
scalar defaults match the presence markers in generated proto3 schemas.

## Decoding

`WireReader` validates each key and length before reading. A varint has at most
ten bytes and its tenth byte contains at most one payload bit. Length-delimited
fields must fit both the remaining source and the protobuf size limit. Unknown
groups are skipped with a bounded, matching start/end field-number walk.

Parsed `WireField` values retain integer bits or exact byte strings. Singular
scalars select their final occurrence. Singular messages concatenate payloads
before parsing their child fields, implementing protobuf merge behavior. Union
selection resets the accumulated payload when a different recognized variant
appears; repeated occurrences of the current variant merge. Unknown fields do
not change the selected variant.

Schema-directed decoding requires each non-optional field, validates the wire
kind, and constructs children before calling reflected construction for the
parent. No partially constructed value is published after a failure. Type
lookup uses the destination state's initialized nominal registry; the nominal
helper checks both name and requested record/union kind. It does not guess a
module name or execute a module loader.

The reader limits nesting and message size. Native reconstruction supplies the
final C range, qualifier, fixed-array extent, and construction checks. A decoded
pointer remains a borrowed address. No GC object from the source state enters
the destination heap.

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

The Unix and Windows standard providers include `titan.protobuf`, its Lua shim,
and its native tests in the shared inventory. Both `titan.lua` and `titan.async`
import the codec so its loader is available in independent-state preload
snapshots and Receiver-only applications. Explicit nominal carriers retain
their serialized names and bytes. Closure graph reconstruction uses the codec
to decode nominal captures against the receiving state's initialized types;
no operation reads another state's reflection descriptors.

Tests belong in `spec/stdlib/titan/protobuf/`, with transfer lifecycle cases in
the Lua/async native owners and reflection/code-generation tests in their
existing layers. Cover full-width scalars, binary strings, custom constructors,
const fields, foreign aggregate projections, nil Array positions, graph
rejection, unknown fields, merge rules, malformed inputs, and schema/wire
agreement with an independent protobuf implementation. Foreign exportability
also needs a source-free compiled-consumer gate using the real declaring C
header.
