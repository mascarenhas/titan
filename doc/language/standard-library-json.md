# JSON standard library

`titan.json` converts Titan data to JSON strings and reads JSON as dynamic data
or as an explicitly supplied [reflection schema](standard-library-reflect.md).
It supports nested Arrays, Maps, public record fields, and tagged unions.
Import it with `local json = import "json"`; Lua uses
`require "titan.json"`. Both operations are synchronous and need no async
Runtime.

Save this example as `json_example.titan`:

```titan
local json = import "json"
local reflect = import "reflect"
local io = import "io"

record Person
  const name: string
  const score: integer
end

union Message
  person(Person)
  idle()
end

function main(args: {string}): integer
  local original = Message.person(Person.new("Ada", 42))
  local text = json.encode(original)
  io.print(text)
  local schema = reflect.Type.is_named(
    reflect.NamedType.new("json_example.Message"))
  local restored: Message = json.decode(text, schema)
  case restored
  when person(person) then
    io.print(person.name, person.score)
  when idle() then
    io.print("idle")
  end
  return 0
end
```

The encoded message is
`{"tag":"person","value":{"name":"Ada","score":42}}`. Supplying the
schema reconstructs the nominal `Message` and `Person` values, including their
const fields. Without a schema, the same document decodes to ordinary Maps.

## Public API

```text
encode(subject: value, ...: EncodeOption): string
decode(source: string, target: reflect.Type?, ...: DecodeOption): value

EncodeOption.null_value(value)
EncodeOption.max_depth(integer)
EncodeOption.max_bytes(integer)
EncodeOption.max_nodes(integer)

DecodeOption.null_value(value)
DecodeOption.max_depth(integer)
DecodeOption.max_bytes(integer)
DecodeOption.max_nodes(integer)
DecodeOption.ignore_unknown_fields(boolean)

Error.code: string
Error.message: string
Error.position: integer?
Error.line: integer?
Error.column: integer?
Error.path: string
```

Every `Error` field is const. Errors are raised, so a successful decoding of
`null` can return nil without being confused with failure. Options are union
values; when an option occurs more than once, the last occurrence wins.
Invalid option values raise before processing the input.

Omit `target` for dynamic decoding. To supply decoding options without a target,
pass nil explicitly: `json.decode(text, nil, json.DecodeOption.max_bytes(4096))`.
An annotated local, parameter, or return can recover the concrete result of a
schema-directed call; there is no `decode<|T|>` type-inference API.

## Values and containers

| Titan value | JSON |
| --- | --- |
| nil | `null` |
| boolean | `true` or `false` |
| integer | Exact decimal integer |
| finite float | Decimal number with round-trip precision |
| string | UTF-8 string with JSON escaping |
| mutable or const Array | Array, visiting every position from 1 through its length |
| Map with string keys | Object |
| record | Object containing its public fields |
| union | Object with the variant name in `tag` and its payload in `value` |
| Interface | Object containing its captured public fields; encoding only |

Dynamic decoding returns scalars, Titan `{value}` Arrays, and
`{string: value}` Maps. Empty Arrays encode as `[]`; empty Maps and records
without public fields encode as `{}`. An integer-keyed Map is not an Array,
and non-string Map keys raise `invalid_map_key`. A Map target schema must
accept string keys (`is_string` or `is_value`), even for an empty object.

Output is compact. Record fields follow declaration order. Map keys are sorted
by their bytes, and union envelopes write `tag` before `value`. This ordering
is deterministic, but it is not a cryptographic JSON canonicalization format.
Map enumeration uses existing entries; metatables do not manufacture members.
Methods, statics, and source-private fields are not serialized.

Functions, threads, pointers, owned foreign values, and opaque userdata have
no default representation. A public field containing such a value raises at
that field. Interface encoding reads its captured public fields rather than
unwrapping the concrete receiver; decoding an Interface is unsupported because
the fields do not identify a concrete implementation.

Cycles raise `cycle`. Repeated references to the same acyclic value are allowed
and serialize separately; decoding does not preserve shared object identity.
Encoding and decoding do not mutate their input values or expose a partial
result after failure.

## Nulls and holes

By default, JSON null becomes nil. Titan stores nil as absence in containers,
so this policy has observable consequences:

| JSON input | Decode, then encode with default options |
| --- | --- |
| `[1,null,3]` | `[1,null,3]` |
| `[1,null,null]` | `[1]` |
| `[null]` | `[]` |
| `{"x":null}` | `{}` |
| `null` | `null` |

An internal Array hole remains visible because a later element retains the
Array's length. Trailing nil positions shorten the Array, and a Map member
whose value becomes nil disappears. Decoding still validates every source
position/member before applying these rules, including duplicate null-valued
members.

Supply a nonnil token when nulls must survive in dynamic data. Save this example
as `json_nulls.titan`:

```titan
local json = import "json"
local io = import "io"

local record NullToken
end

function main(args: {string}): integer
  local token = NullToken.new()
  local data: value = json.decode("[1,null,null]", nil,
    json.DecodeOption.null_value(token))
  io.print(json.encode(data, json.EncodeOption.null_value(token)))
  return 0
end
```

The token is compared using raw value equality before ordinary encoding
dispatch. Reuse the same token for both calls. A dedicated record instance
avoids confusing real application data with null. False, zero, and empty-string
tokens also work, but encode every equal data value as null; numeric equality
includes `0` versus `0.0`. A NaN token is rejected. Passing nil restores the
default. Tokens apply to data values, never object keys or generated union tags.

The sentinel is used for untyped decoding and `is_value` schema leaves,
including container elements whose type is `value`. Typed decoding retains
these distinctions:

- Explicit nil and Option targets decode null as nil, even with a token.
- A concrete Array element or Map value can decode null as a hole/absent entry;
  a token does not insert a foreign value into `{integer}` or another concrete
  container.
- A required scalar, record field, root record/union, or nonnullable union
  payload rejects null. A `value` field or payload uses the sentinel policy.
- A missing nil-admitting record field becomes nil. Absence is not explicit
  JSON null and never creates a sentinel.

## Records and schemas

Use `reflect.Type.is_named(reflect.NamedType.new("package.Record"))` for a
nominal target, with the declaration's fully qualified module name. The module
that defines it must already be initialized. JSON does not import modules, and
an unknown nominal name raises `unknown_type` rather than becoming dynamic.

Structural descriptors can request individual scalars, Options, Arrays, or
Maps. For example, this complete module exposes a decoder for integer Arrays:

```titan
local json = import "json"
local reflect = import "reflect"

function read_integers(text: string): {integer}
  local schema = reflect.Type.is_array(reflect.ArrayType.new(
    reflect.ArrayTypeConstness.is_mutable(), reflect.Type.is_integer()))
  return json.decode(text, schema)
end
```

Automatic record decoding calls the public synthesized `new` constructor after
validating every argument. This initializes both mutable and const fields.
Missing fields are accepted only when the field descriptor admits nil: nil,
Option, or `value`. Required booleans are required even though false is falsy.
Unknown members normally raise `unknown_field`; pass
`DecodeOption.ignore_unknown_fields(true)` to allow extra record members.
Ignored members still undergo syntax and resource validation.

A local record, or a record with any local field, has no public synthesized
constructor. Its public view can be encoded, but automatic decoding raises
`constructor_unavailable`. Decode ordinary data and invoke an application
factory when such a type must be reconstructed. JSON does not guess factories
or expose private fields.

Recursive nominal schemas are resolved as their values are visited. They do not
need eager expansion. Reflection erases generic arguments: `Box<|Person|>` and
`Box<|string|>` have the same runtime nominal schema, and an erased `T` may look
exactly like a declared `value`. Such a leaf decodes dynamically; projecting
the outer result does not prove a generic specialization. Use an explicit
application decoding function when specialization-specific reconstruction is
needed.

Decoded mutable Arrays are built through `{value}` storage. Schema validation
checks their initial contents, but a later typed view retains that storage's
Lua-writer policy. Every later typed Titan read still checks the element.
Const Array targets produce const Arrays and reject writes. Maybe-const Array
targets produce mutable Arrays. See [Arrays and Maps](arrays-maps.md).

## Tagged unions

Union envelopes use fixed `tag` and `value` member names:

| Titan value | JSON |
| --- | --- |
| `Message.idle()` | `{"tag":"idle"}` |
| `Message.count(3)` | `{"tag":"count","value":3}` |
| `Message.optional(nil)` | `{"tag":"optional","value":null}` |

The discriminator is the public variant arm name, not its numeric runtime tag
or the union's type name. An object payload remains nested under `value`, so its member names do not
collide with the envelope. A Map payload can contain both `"tag"` and `"value"`
keys.

Typed decoding requires one string tag identifying a public arm of the expected
union. A payload-bearing arm must have `value`, including when its permitted
payload is nil. A payloadless arm must omit `value`, even when it would be null.
All other envelope members are rejected, including with
`ignore_unknown_fields(true)`. Encoding an active private arm raises
`private_variant`; decoding an unknown public arm raises `unknown_variant`.

Without an explicit union schema, an object containing `tag` is an ordinary
Map. JSON never chooses a nominal type from untrusted text.

## Strings and numbers

The accepted syntax follows [RFC 8259](https://www.rfc-editor.org/rfc/rfc8259.html).
Every JSON root kind is accepted, with space, tab, CR, and LF as whitespace.
The document must be complete. Comments, trailing commas or other trailing
data, malformed numbers/literals/escapes, raw control bytes, and a leading BOM
are rejected. Duplicate decoded object keys are rejected, including `"a"`
versus `"\u0061"`.

Strings must be valid UTF-8. Escaped surrogate pairs combine into their Unicode
scalar; lone surrogates and invalid UTF-8 are rejected. Embedded NUL round-trips
through `\u0000`. Unicode is not normalized. Encoding a Titan byte string that
is not UTF-8 raises `invalid_utf8`.

Dynamic decoding preserves integer-form tokens as exact Titan integers, raising
on integer overflow. Tokens with a fraction or exponent become finite floats.
An integer schema accepts exactly integral, in-range decimal tokens such as
`1.0` and `1e3`. The check uses the decimal value, so
`9007199254740993.0` does not silently round to a different integer.

A float schema allows normal floating-point rounding, including integer-form
tokens outside the integer range. Overflow and nonzero values that underflow to
zero are rejected. Float negative zero is preserved. Integral floats encode
with a fraction or exponent marker so dynamic decoding retains their numeric
kind; integer-form `-0` may normalize to integer zero. Nonfinite input floats
cannot be encoded. Conversion does not change the process-global numeric
locale.

Full-range Titan integers are emitted as numbers. Other JSON consumers may
round integers beyond their own exact numeric range; JSON does not provide an
arbitrary-precision number type or silently convert these values to strings.

## Diagnostics and limits

Catch `json.Error` to inspect a structured failure. Its `code` is stable;
`message` explains the failure. `position` is a one-based source byte offset,
and `line` and `column` use the same byte-oriented convention as
`peg.line_column`. CRLF counts as one line ending; CR and LF also work. An EOF
position is one past the last byte. These fields are nil for failures without
a source location, such as encoding errors or invalid options.

`path` starts at `$`, uses quoted object members such as `$["address"]`, and
one-based Array indices such as `$["people"][2]`. Syntax errors use `$` when
there is no semantic path yet. For example, `[1 2]` reports
`expected_array_separator` at byte 4, and `true false` reports
`trailing_input` at byte 6. Unexpected runtime failures retain their original
error and traceback instead of being reported as malformed JSON.

The default limits are 16 MiB of input/output text, 1,000,000 visited JSON
values, and a nesting depth of 32. `max_depth`, `max_bytes`, and `max_nodes`
require positive integers. Depth counts JSON
containers: a root object or Array has depth 1, and a union envelope is an
object. The node count includes the root, nulls, and ignored record members'
values. Decode's byte limit applies to the complete input; encode's limit
applies to emitted text. Exceeding a limit raises `limit_exceeded`.

The configured depth is a container budget, not a guarantee that every document
within it fits the available execution resources. Parsing also consumes PEG
matching-stack and delayed-capture recursion space; decoding and encoding use
their own traversal space. JSON does not modify PEG's shared stack limit or
convert independent engine/runtime failures into JSON limit errors. Applications
can choose `peg.set_max_stack` for their workloads; documents with nested sibling
lists can need more matching-stack space than equally deep single-child chains.
Streaming,
pretty printing, field renaming, custom codec registries,
reference preservation, and automatic generic type tokens are outside this API.

See [JSON implementation](../implementation/json-library.md) for the parser,
reflection, and allocation design.
