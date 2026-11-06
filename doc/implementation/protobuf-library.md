# Protocol Buffers library

The public contract is [Protocol Buffers standard
library](../language/standard-library-protobuf.md). The logical `titan.protobuf`
module has four source contributors in `titan/protobuf/`: `protobuf.titan` owns
the public API, resource-codec registry and shared scalar/type helpers,
`encoder.titan` owns graph traversal, `decoder.titan` owns wire parsing and
reconstruction, and `schema.titan` owns proto3 declarations. `native.h` holds
the reflective decoder's directory entry and includes the SDK header
`titan-runtime/transfer.h`, which owns the shared buffer and the generated-codec
runtime. The module imports `reflect`, `string` and `gc`; it does not depend on
the asynchronous runtime, `titan.transfer` or the independent-state wrapper.

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
                                        length: integer,
                                        nominal: reflect.NominalType?,
                                        name: string, is_union: boolean,
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
inspected-root helper records its starting length, creates one `Encoder`
carrying `context`, appends the already-inspected root at depth 1, and checks
the appended message size. Its `context` has a deliberate ambient fallback: when
the caller passes `nil`, the helper substitutes `packet_context(true)`, the exact
top encode scope of the current execution (or `nil` when there is none), which
is what lets the public `serialize_to_buffer` pass no context. The caller
retains buffer ownership and must provide its normal native-buffer cleanup;
these entries neither initialize nor finalize that storage.

`deserialize_nominal_buffer_with_context`,
`serialize_fields_to_buffer_with_context`, and
`deserialize_fields_buffer_with_context` have no such fallback. They hand the
caller's already-resolved encode or decode `context` to the `Encoder` or
`Message` verbatim, so an explicit `nil` carries no attachment/claim authority:
the registered `ResourceCodec` callbacks raise
`transfer: resource attachment requires an encode scope` or
`transfer: resource claim requires a decode scope`, even when the call is made
from an opaque `to_transfer_payload` / `from_transfer_payload` hook whose packet
scope is active for the same execution. The public `deserialize_nominal_buffer`,
`serialize_fields_to_buffer`, and `deserialize_fields_buffer` wrappers resolve
`packet_context(true)` / `packet_context(false)` once and delegate to them, and
`titan.transfer` passes its already-resolved `ResourceScope` directly.

Nominal roots likewise carry the descriptor the caller already found. The
`nominal` argument of `deserialize_nominal_buffer_with_context` is the caller's
`reflect.find_nominal(name)` result: `deserialize_nominal_buffer` and
`deserialize_nominal` look it up once themselves, and transfer's packet worker
passes the result of the lookup `initialize_nominal_raw` performs before or
after loading the declaring module. The shared slice raises the unknown-name
error for nil and the kind-mismatch error otherwise, then hands the record or
union descriptor to private `deserialize_record_buffer` /
`deserialize_union_buffer`. Those check the message size and require public
members. A descriptor whose name has a
[generated codec](#generated-nominal-codecs) (`find_named_codec`) then decodes
through it with the caller's context and holder; any other root slice is parsed
and decoded reflectively. These name-based roots therefore perform one registry
lookup and allocate no `reflect.Type` wrapper.

`deserialize(bytes, descriptor)` reaches the same helpers after `resolve_type`.
A `Type.is_record` / `is_union` descriptor dispatches directly. A
`Type.is_named` descriptor first checks `find_nominal` and then calls
`NamedType:resolve()`, whose state-local cache
([reflection](standard-library-reflect.md#descriptor-hydration)) allocates
that name's wrapper only on its first resolution in the state. Root errors keep
one order on every entry: descriptor or name resolution (unknown nominal,
cyclic alias), root-kind rejection (not a record or union, nominal kind
mismatch), then the 2 GiB size check, then the public-member check. For
`deserialize` this resolves the descriptor before the size check, so an input
over 2 GiB with an unknown or non-nominal root descriptor reports the
descriptor error.

`titan.protobuf` never imports `titan.transfer` or `titan.thread`. Instead,
`transfer` installs its `packet_context` resolver once via
`set_packet_context_provider` and mediates capability registration via
`transfer.register_resource` -> `protobuf.register_resource_codec`. That
resolver answers `nil` without resolving the current execution while no packet
frame is installed anywhere in the Lua state (`active_scope_count` in the
[transfer scope mechanics](transfer-library.md#scoped-resource-table-and-manual-resource-ownership)),
so a standalone `serialize`/`deserialize` costs one
provider call and one integer test rather than an execution lookup.
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

`Encoder:record_value` and `union_value` enforce public nominal and complete
member visibility, active-path cycle detection, the [nesting
limit](#nesting-limit), and the normal field and variant traversal with
nested custom-hook dispatch. The
inspected-root helpers check the 2 GiB message limit after encoding. Root
custom-hook and root resource-codec selection belong to `titan.transfer`;
ordinary `protobuf.serialize` keeps its structural public-data rules. See the
[owning API inventory](../language/standard-library-protobuf.md#api) and
[transfer classification](transfer-library.md#flat-packets-and-direct-classification).

## Nesting limit

One budget, `TITAN_CODEC_DEPTH_LIMIT`, bounds every codec path. It is
defined in `titan-runtime/transfer.h` as 128 on both native and browser
targets. `titan/protobuf/native.h` includes that header, so `protobuf.titan`
reads it as `ffi.TITAN_CODEC_DEPTH_LIMIT` through its existing import. The reflective
`require_depth` (used by the encoder, the decoder, and `schema`) and the
generated codecs' `titan_codec_depth` (also used when their field reader skips
a group) raise when a depth exceeds the budget, with `protobuf: nesting
exceeds <budget> levels` built from the macro in both. The budget is raw:
each record or union with fields probes them one level deeper, so 128 accepts
a 127-record chain, while a union whose selected variant has
no parts probes nothing deeper and is accepted at the budget itself. There is
no reflective-only limit and no separate `transfer` constant: `transfer`
encodes and decodes through these paths, so the one define bounds it too.
The boundary tests derive their depths and messages from the macro:
`encode_127_accepted`, `decode_128_rejected_by_both`, and
`partless_union_at_128` apply on both targets.

## Generated nominal codecs

The compiler emits a codec pair for every public record or union that the
reflective codec could encode (`coder/nominal_codec.lua`): every field or
variant is public, no member is named `to_transfer_payload` or
`from_transfer_payload`, and every field or part type is `nil`, a boolean,
integer, float, string, `value` (including erased generic parameters),
record, union, Titan Array, or a foreign integer, float, pointer, complete
struct, or fixed array, or an Option of one of those. Eligibility is per
nominal, so recursive declarations never depend on declaration order. A
nominal with a field the reflective codec always rejects (callables, Maps,
Interfaces, owned or union C types), private members, or hooks stays entirely
reflective, as does a nominal whose decoder frame would exceed 64 directory
entries: a record's fields, or one union selector plus the largest variant's
parts. Each entry is 32 bytes at up to `TITAN_CODEC_DEPTH_LIMIT` nesting
levels (128 on both native and browser targets). The union selector
validates the complete wire message but stores only the one recognized
occurrence; zero, repeated, replaced, or non-message variants hand back to the
reflective decoder after that validation. One shared parts directory serves
the selected variant, so variant count does not grow that directory. Wider
records or payloads stay reflective, whose per-level C stack does not grow
with field count. Deep reflective decoding and its error traceback can still
exhaust a coroutine's C stack in unoptimized (`-O0`) builds.

The declaring module emits one `TitanTransferCodec` entry per codec and
binds the nominal's canonical metatable to it under `TITAN_MT_CODEC`
([closure transfer metadata](codegen-overview.md#cross-state-closure-transfer-metadata)).
These layouts and the inline codec runtime in `transfer.h` are generated-code
ABI that no load-time check covers
([compiled-module ABI](codegen-overview.md#compiled-module-abi)).
`find_generated_codec` reads the binding with raw table reads and returns nil
when the metatable also has a registered resource codec
(`transfer.h` `titan_codec_for_metatable`), so resource capabilities keep their
precedence. Erased generic applications share the one metatable and entry.

The entry's address is the nominal's codec identity tag; no codec path
compares nominal names. The entry is an element of the declaring module's
`TITAN_MODULE_PRIVATE const` `<prefix>\u2119_transfer_codecs` array, defined
once in the module's part 0 (internal linkage when the module is unsplit; an
unexported symbol shared by its parts when it is
[split](codegen-overview.md#translation-unit-parts)), not a
string literal, so the linker cannot merge it with another nominal's entry,
and each entry also points at its own distinct name. The address is defined
exactly once in each image that contains the declaring module, and no other
module names it: consumers learn it only from the canonical metatable binding
that the declaring module's initializer installs in each Lua state. Every
comparison therefore happens within one state, between entries that the
state's single canonical module instance published. This holds unchanged for
an archive member linked into an executable or DSO, a separately opened DSO,
and a Windows DLL. There are no cross-image data references, symbol
interposition, or `dllimport` thunks. Two images that both embed one module
carry two entries, but a state binds only its canonical instance's entry. A
generated field encoder or decoder needs no comparison. The static field type,
or the declared type's canonical metatable that the decoder is passed, fixes
the metatable whose bound entry it calls. The reflective `Encoder:field`, whose
descriptor and candidate can disagree (for example under `serialize_fields`),
selects a generated codec (`find_field_codec`) only when the candidate's
metatable is the canonical metatable registered under the descriptor's name:
one Map read and one pointer comparison, since that metatable binds the
nominal's sole entry. It then reads that entry once and requires the matching
record or union kind. Otherwise, including a matching nominal without a
generated codec or with a registered resource capability, it falls back to
reflection, which encodes a matching nominal and raises `protobuf: record type
mismatch`, `protobuf: union type mismatch`, `protobuf: expected a record`, or
`protobuf: expected a union` for a mismatch.

A generated codec *is* the reflective codec specialized to one storage plan,
sharing one root state with it (`TitanCodecState`): the buffer, the packet
context, the reflective `Encoder`'s active Map, a C-stack path of the open
generated frames, and one Lua stack slot holding the root's reusable
`Encoder`. It writes identical bytes and raises the identical error string at
the identical point; it never declines or reruns. Booleans, integers, floats,
strings, their Options, nested records and unions, and the nil and scalar arms
of `value` fields are encoded natively, nested nominals through their own bound
codec after the same registered-resource check by expected type. Every other
field, including a `value` holding a nominal or Array, is handed to the
reflective field codec through one fixed Titan entry (`codec_handoff`), called
through its native entry like any first-class Titan call. Each call checks
only the closure's shape and `TITAN_BRAND` by pointer, with no string
comparison. `titan.protobuf`'s initializer, the sole producer of
`TitanCodecState.handoff`, checks once per Lua state that `codec_handoff`'s
function-type tag spells `TITAN_CODEC_HANDOFF_TYPE`, the exact type
`function (value, value, value, value): (value)`, and raises
`protobuf: invalid codec handoff` otherwise, so a changed handoff signature
fails module initialization. `spec/coder/nominal_codec_spec.lua` pins that
spelling and the `TitanCodecHandoffEntry` typedef to the compiler's own
function-type identity and native-entry signature. A generated codec compiled
against another `transfer.h` relies on the one-SDK rule. A registered resource
field runs the reflective resource branch with the carried context (resolved
from the current execution only when the root carried none). Any other field
runs `Encoder:field` with the
field's hydrated descriptor on the state's `Encoder`: the enclosing reflective
`Encoder` when `Encoder:generated` entered the codec, otherwise one created by
the root's first such handoff and rooted in the state's stack slot until the
root returns. Each handoff sets that `Encoder`'s `path` to the handing frame's
path for the field. In the other direction `Encoder:field` and `decode_field`
check resources before calling a generated record or union codec, if present.
The encoder looks up the codec before hooks, while the decoder checks hooks
first; behavior is identical because hooked nominals never receive a generated
codec. These checks precede value inspection. Cycle detection consults
both the active Map and the path, so cycles through mixed frames raise
`protobuf: cyclic object graph` exactly as on the reflective path, and depth
is passed through both sides unchanged. An encoding frame with any field that
can reach the reflective codec (a handed-off field, a `value`, or a nested
nominal) pushes its record onto the Lua stack, so a hook that drops the last
reference to it and collects cannot free the record under the frame.
Generated nil result and reusable scratch slots are initialized through
`setnilvalue2s` before advancing the Lua stack top, following the coder's
stack-aware slot-initialization contract.

A `value` field is one nested `TitanValue` message (absent when nil) holding a
single arm: 1 boolean, 2 sint64, 3 double, 4 bytes, 5 a nominal as {1 module,
2 qualified name, 3 the bytes a field of that nominal type carries}, or 6 a
Titan Array of `TitanValue` elements. The reflective `Encoder:dynamic` and
`decode_dynamic` own the arms; decoding selects the last recognized arm, a
message with none is nil, and Array constness is the observed one. The nominal
arm decodes through `decode_field` with the resolved record or union
descriptor, so hooks, registered resources, and generated codecs apply as for
a static field. Lookup uses the registered nominal; `titan.transfer`
installs `set_nominal_loader(initialize_nominal)` so a packet decode (a
non-nil context) loads the named module on demand, exactly as for a packet
root, in any destination state. A generated decoder reads one length-delimited
`TitanValue` holding at most one scalar arm natively and hands every other
`TitanValue` to `decode_field` through the frame's one-field `Message`; a
generated encoder writes the nil and scalar arms and hands a nominal or Array
to the state's `Encoder`.

The generated decoder mirrors `read_message_slice` and `decode_field`: it
validates the complete message first with the same error strings (keys,
varints, lengths, groups and their depth, wire kinds), recording the latest
occurrence of each declared field, then checks depth and decodes the declared
fields in order with the reflective missing-field, wire, and boolean checks.
Nested messages are parsed when their field is decoded. A field without a
native decoding (and a present `nil`-typed field, whose slice the reflective
decoder validates) runs `decode_field` with the field's hydrated descriptor on
a `Message` holding only that field's single latest occurrence (or none):
`decode_field` reads only the latest occurrence of its number, so it decodes
exactly as from the parsed message, and one such `Message` per decoding frame,
rooted in a frame stack slot, serves all of the frame's handed-off fields. A
repeated field, which merges, reparses the frame's message instead, as does a
union message with other than exactly one length-delimited recognized
occurrence for the whole union. An absent optional field is nil without a
handoff. Decoding allocates the destination with the reflective constructor's
storage steps (`luaS_newudata`, module metatable, zeroed payload), roots it
before any other allocation, stores traced fields with `luaC_barrierback`, and
never calls `new`. Reflectively decoded fields stay on the Lua stack until the
frame has decoded every field and are then stored through the reflective
constructor's field conversions in field order, because `decode_record`
decodes every field before `construct` converts any: a later malformed field
therefore raises before an earlier field's conversion error, and every
field's hooks and resource claims run first, as on the reflective path.

Native string decoding publishes the new `TString` into the rooted record or
union and applies its backward barrier before `luaC_checkGC`. The scalar
string arm of `value` likewise pushes the result before polling. This matches
the reflective decoder's `lua_pushlstring` allocation and poll order without an
extra copy or transient root. Deferring the poll to the next entry would let a
trimming allocator such as glibc's return its free tail before each large
string allocation, repeatedly releasing and faulting the same pages.

Generated codecs serve `serialize_to_buffer` (before `reflect.inspect`), the
inspected-root entries, `deserialize`, `deserialize_nominal*`, transfer
packets, and every nested record or union reached by either codec; a nominal
with a codec always decodes through it. The collaboration entry
`serialize_generated_to_buffer` runs only the generated root, and the
diagnostic `use_generated_codecs(false)` makes the whole state reflective,
which native differential tests use as the oracle.

## Encoding

The encoder keeps an active-path Map keyed by the original nominal or Array
value. A deferred removal accompanies every entry, so exceptions unwind the
cycle detector. Shared values outside the active path are encoded again. The
encoder does not prevalidate the entire declared type graph; it resolves and
checks descriptors as their values are visited. Union traversal visits the
active payload only; the all-public type flag still rejects private variants
anywhere on that nominal declaration.

All wire accumulation writes into a pluggable, expandable native buffer,
`titan_protobuf_buffer` (`data`, `length`, `capacity`, a `context` pointer and a
`grow` callback). The buffer, its writers and the fixed64/double readers live in
the SDK header `titan-runtime/transfer.h` because generated nominal codecs in
every module append through them.

`titan_protobuf_buf_reserve(buf, extra)` computes `needed = length + extra`
(failing if that overflows `SIZE_MAX`) and starts from `max(capacity, 64)`:

| Case | Requested capacity |
| --- | --- |
| bulk: `extra > 4 * max(capacity, 64)` | `needed + max(256, needed / 8)` (division rounds down); exactly `needed` if the slack would overflow |
| otherwise | the largest power of two no greater than `max(capacity, 64)`, doubled until `needed` fits; exactly `needed` if the next doubling would overflow |

The bulk slack absorbs proportional trailing fields, packet metadata and
attachment entries without retaining the next power-of-two block for one large
byte field: at most 12.5% of `needed` for requests of at least 2,048 bytes, and
256 bytes for smaller bulk requests. Growth after a bulk allocation rejoins the
power-of-two sequence instead of doubling an off-sequence capacity, so streams
of small writes stay amortized O(1). Later writes that together exceed the bulk
slack trigger a second payload-sized reallocation through normal growth. A NULL
`grow` fails the reservation; the heap grower `titan_protobuf_heap_grow` leaves
`data` and `capacity` unchanged when `realloc` fails.

Transfer's structural packets (`init_packet_buffer`,
[flat packets](transfer-library.md#flat-packets-and-direct-classification))
reserve the packet header plus at most 64 metadata bytes up front. On supported
targets that request stays below an empty buffer's 256-byte bulk threshold, so
it takes the doubling branch and never receives bulk slack. A 64 KiB top-level
byte field then causes one bulk growth after the small initial allocations, and
ordinary metadata and a one-endpoint attachment tail fit in its slack.

Because serialization can raise (`longjmp`) after buffer growth, callers
allocate the descriptor as GC-owned storage
(`owned *titan_protobuf_buffer = foreign titan_protobuf_buffer.new()`), not a
stack-spilled automatic C aggregate across `setjmp`, and pair
`titan_protobuf_buf_init_heap` with `defer ffi.titan_protobuf_buf_free_heap(buf)`
so `buf->data` is freed on normal exit or unwind. String-returning entry points
use such a heap buffer outside the Lua GC and materialize the final Lua string
once at the root. Never keep an interior `data` pointer across a reservation.

No sizing pass replays a custom encoder. Nested length-delimited
messages reserve a one-byte length slot at `begin_nested` and patch or shift in
place at `end_nested`, avoiding intermediate per-message writers or string
allocations.
Varints use logical shifts on the 64-bit integer carrier, including unsigned bit
patterns represented by negative Titan integers. ZigZag preserves the complete
signed range. Fixed floating and pointer payloads write little-endian bytes
directly into the buffer. Foreign signedness and width checks run before
publication. Structs use member order; nested fixed arrays use their projected
values and target construction validates the actual C extent without evaluating
C expressions in Titan.

`find_transfer_hooks` memoizes the validated `(encode, decode)` pair of
`reflect.MethodType` and `reflect.StaticFunctionType` (or a negative sentinel)
per nominal record name (`descriptor.name`) in a module-local Map, and
`encode_transfer_payload` shares the module-local
`active_record_payloads` ephemeron Map so nested (`depth > 1`) and root hook
invocations enforce one reentrancy guard without permanently rooting abandoned
encoding graphs. Lexical removals restore that guard on normal and error exit.
Nested records (`depth > 1`) first check `find_resource_codec_by_name`. When a
registered `ResourceCodec` matches `expected.name`, `Encoder:field` calls
`encode_resource_field`, which checks `record_identity(candidate)` against
`codec.identity`, calls `codec.encode(self.context, candidate)` with the
packet's carried context, and writes the wire key, length 4 and the four-byte
little-endian slot index through `write_resource_index`, without
`reflect.inspect` or a four-byte Lua string. Generated codecs run the same
function for their resource fields. Other nested records that provide both
`to_transfer_payload` and `from_transfer_payload` encode as `optional bytes`
through their hooks instead of requiring public fields.

Array wrappers retain slot positions and distinguish absence from an empty
container. Nil slots produce empty element messages. The constness field
preserves a maybe-const Array's actual state. Nil/optional omission and explicit
scalar defaults match the presence markers in generated proto3 schemas.

## Decoding

`WireReader` (`base`, `limit`, `position`) reads a `const uint8_t *` buffer
directly, validating each key and length before reading. A
varint has at most ten bytes and its tenth byte contains at most one payload
bit. Length-delimited fields must fit both the remaining source and the protobuf
size limit. Unknown groups are skipped with a bounded, matching start/end
field-number walk.

Each message owns a compact native directory of `titan_protobuf_field` entries.
An entry contains a field number, wire kind, integer bits or `(offset, length)`
slice, a previous-occurrence ordinal, and an index-chain ordinal; it contains
no GC pointers. The first entry lives inline in `Message`. Empty and
single-field messages allocate neither entry storage nor a lookup index. The
second entry allocates a counted `owned titan_protobuf_field[]` of capacity
four for entries after the inline first entry, doubling only when full. Growth
copies populated overflow entries, not wire bytes, and finishes before any
decoder borrows an entry address. There is no per-field record, Array
proxy/backing table, external malloc/free lifetime, or finalizer.

The first lookup in a multi-field message builds one zeroed, counted
`owned uint32_t[]` index. Its power-of-two capacity is at least twice the entry
count, and its size depends on the encountered field count, never the largest
numeric tag. Each bucket heads a chain of 1-based directory ordinals, with zero
as the empty sentinel. A chain links only the latest entry of each distinct
field number: insertion records the entry's preceding same-number occurrence
and lets the new entry take over that occurrence's chain position, so singular
scalars select only their final occurrence and repeated tags never lengthen a
chain. A probe visits only the distinct numbers sharing its bucket, so
adversarial tags cannot build open-addressing clusters across buckets.
Building the index takes expected linear time; later scalar lookups take
expected constant time. Ordered-only Array and union readers allocate no index.

Single-occurrence embedded messages and union variants parse child fields in
place. Repeated singular messages validate every matching occurrence's wire
kind, follow only same-number links, and concatenate slices in encounter order
before parsing the merged child. Merge scratch Arrays contain integer ordinals,
not wrappers for entries. Union traversal likewise keeps ordinals and discards
earlier chunks on a recognized variant change; unknown fields do not change the
selection. Array traversal retains wire order, slot positions, and the final
constness marker. Unknown-group contents are validated and skipped without
directory entries for their children.

The owning `Message` remains traced throughout entry and byte-slice use. Its
`holder` retains the backing string and is propagated to child slices: string
entry points pass their input as the root holder, and merged children hold
their concatenated merge string. A custom decoder that drops its caller's last
input reference therefore cannot free the bytes behind `Message.base`; native
call inputs alone are not roots ([values and GC](values-and-gc.md#calls-c-only-inputs-immediate-result-roots-and-vm-transport)).
Raw-buffer entry points pass no holder and retain their existing synchronous
caller-owned borrow contract. Neither an entry pointer nor `Message.base` owns
its bytes. Directory owners and holders therefore survive allocations,
reentrant custom decoders, and collection in a custom decoder without an
untraced owner hidden in native storage.

For allocation attribution, `Message:append`'s `self:entry(self.count)` call
runs once per wire-field directory entry, and `decode_field`'s
`require_depth(depth)` call runs once per decoded field, including recursive
Option dispatch.

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
both name and requested record/union kind and never guesses a module name.
Protobuf itself executes no module loader, with one exception: the nominal arm
of a `value` field names its declaring module, and while decoding with a
packet context (a non-nil `Message.context`) a missed name runs the loader
`titan.transfer` installed (`set_nominal_loader(initialize_nominal)`), then
looks the name up once more. Standalone decoding has no context and loads no
module, and `TransferValue:to_value` outside a packet loads only its root's
module (transfer's own step), never one named inside a `value`.

Every reconstruction builder (record fields, union parts, foreign-struct fields,
and foreign or const Array entries) is a fresh decoder-local Array, and every
const result is produced by a standalone `local frozen = ... as const {value}`
declaration. For records, unions, foreign structs, and foreign arrays the cast
operand is the builder local itself, which the checker's
[linear-use proof](const-values.md#array-relations-and-linear-use-analysis)
freezes in place. A const Array casts the result of a `decode_array_entries`
call instead; that function only returns its builder, so its declared result is
linear and the written cast of the call result also freezes in place. Neither
path allocates a shallow copy before `construct` or the parent field consumes
the Array. `decode_array` first selects the result shape from the declared
constness and, for a maybe-const Array, the final wire marker; a mutable result
returns the `decode_array_entries` builder unchanged. The element walk still
validates every marker occurrence at its wire position before any Array is
returned. Keep these casts out of call arguments and implicitly converted
returns, which would restore the copy.

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

`titan.transfer` dispatches custom record hooks at a packet root before the
structural fallback; `titan.protobuf` dispatches them for nested record fields
as described under [Encoding](#encoding), and `serialize` keeps its public-field
policy at the root. Custom payloads and closure snapshots are immutable byte
strings before they enter the native transfer boundary.

The Unix and Windows standard providers include `titan.protobuf` and its Lua
entry, and its native tests are in the shared inventory. `titan.lua` and `titan.async`
depend on the codec through `titan.transfer`, so its loader
is available in independent-state preload snapshots and Receiver-only
applications. Explicit nominal carriers retain
their defining modules, nominal names, and bytes. Closure reconstruction uses
the codec to decode its snapshot against the receiving state's initialized types;
no operation reads another state's reflection descriptors.

Tests belong in `spec/stdlib/titan/protobuf/`: `protobuf.tests` imports only
the browser subset and runs on both targets, including the raw index writers
and their reservation failure, while `protobuf.resource_tests` holds the
`thread` endpoint cases. Same-instance packet cases are in `transfer.tests`,
cross-state transfer lifecycle cases in the Lua/async/thread native owners,
and reflection/code-generation tests in their existing layers. Keep depth
cases derived from `ffi.TITAN_CODEC_DEPTH_LIMIT` and cover full-width
scalars, binary strings, custom constructors,
const fields, foreign aggregate projections, nil Array positions, graph
rejection, unknown fields, merge rules, malformed inputs, and schema/wire
agreement with an independent protobuf implementation. Foreign exportability
also needs a source-free compiled-consumer gate using the real declaring C
header.
