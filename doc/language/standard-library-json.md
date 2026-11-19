# JSON standard library

`titan.json` encodes Titan values to compact RFC 8259 JSON strings and decodes
JSON into dynamic data or a caller-supplied
[reflection schema](standard-library-reflect.md). All operations are synchronous
and need no async Runtime.

- **Import:** `local json = import "json"` (Titan) · `require "titan.json"` (Lua)
- **Targets:** Native & Browser (complete)

## Quick examples

Decode JSON dynamically into scalars, `{value}` Arrays, and `{string: value}`
Maps, then project values at typed sinks:

```titan
local json = import "json"
local io = import "io"

function main(_args: {string}): integer
  local raw = '{"host":"localhost","port":8080,"tags":["api","v2"]}'
  local config: {string: value} = json.decode(raw)
  local host: string = config["host"]
  local port: integer = config["port"]
  local tags: {string} = config["tags"]
  io.print(host, port, tags[1])

  config["port"] = 8443
  io.print(json.encode(config))
  return 0
end
```

Supply a nominal schema to reconstruct records and tagged unions directly. Save
this program as `json_example.titan`:

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

function main(_args: {string}): integer
  local original = Message.person(Person("Ada", 42))
  local text = json.encode(original)
  io.print(text) -- {"tag":"person","value":{"name":"Ada","score":42}}

  local schema = reflect.Type.is_named(
    reflect.NamedType("json_example.Message"))
  local restored: Message = json.decode(text, schema)
  case restored
  when person(who) then
    io.print(who.name, who.score)
  when idle() then
    io.print("idle")
  end
  return 0
end
```

Without a schema, the same JSON text decodes to ordinary `{string: value}` Maps.

## Encoding and decoding

```text
function encode(subject: value, ...: EncodeOption): string
function decode(source: string, target: reflect.Type?, ...: DecodeOption): value

union EncodeOption
  tag_field(name: string)
  null_value(value: value)
  max_depth(value: integer)
  max_bytes(value: integer)
  max_nodes(value: integer)
end

union DecodeOption
  tag_field(name: string)
  null_value(value: value)
  max_depth(value: integer)
  max_bytes(value: integer)
  max_nodes(value: integer)
  ignore_unknown_fields(value: boolean)
end
```

Failures raise `json.Error`, so decoding `"null"` returns `nil` unambiguously.
When the same option appears more than once, the last occurrence wins. Invalid
option values raise `invalid_option` before the input is processed.

Omit `target` for dynamic decoding. To pass options without a schema, supply
`nil` explicitly:

```text
local data = json.decode(text, nil, json.DecodeOption.max_bytes(4096))
```

Recover the concrete type of a schema-directed decode at an annotated local,
parameter, or return sink.

## Values, containers, and nulls

| Titan value | JSON representation |
| --- | --- |
| `nil` | `null` |
| `boolean` | `true` or `false` |
| `integer` | Exact decimal integer |
| finite `float` | Decimal number with round-trip precision |
| `string` | Valid UTF-8 string with JSON escaping |
| mutable or `const` Array | Array from index `1` through `#array` |
| Map with `string` keys | Object |
| record | Object containing its public fields |
| union | Object with variant discriminator and declared payload parts |
| Interface | Object containing its captured public fields (encoding only) |

Dynamic decoding produces scalars, `{value}` Arrays, and `{string: value}` Maps.
Empty Arrays encode as `[]`; empty Maps and records with no public fields encode
as `{}`. Non-string Map keys raise `invalid_map_key`, and a Map target schema
must accept string keys (`is_string` or `is_value`) even for `{}`.

Encoded output is compact and deterministic: record fields appear in declaration
order, Map keys are sorted bytewise, and union objects write the discriminator
before payload parts in declaration order. Map encoding reads raw entries;
metatables do not synthesize members. Methods, statics, and `local` fields are
omitted.

Functions, threads, raw pointers, owned foreign storage, and opaque userdata
cannot be encoded and raise when encountered. Interface encoding serializes
captured public fields rather than unwrapping the concrete receiver; Interface
decoding is unsupported. Cycles raise `cycle`, whereas shared acyclic references
encode independently. Encoding and decoding never mutate their inputs.

### Nulls and holes

By default, JSON `null` decodes to `nil`. Because Titan represents `nil` in
containers as absence, trailing nulls in Arrays and null-valued Map members are
dropped during dynamic decoding:

| JSON input | Decode, then encode (default) |
| --- | --- |
| `[1,null,3]` | `[1,null,3]` |
| `[1,null,null]` | `[1]` |
| `[null]` | `[]` |
| `{"x":null}` | `{}` |
| `null` | `null` |

Interior Array holes survive because a later non-nil element preserves `#array`.
Duplicate object keys—including keys mapped to `null`—are always rejected before
entries are discarded.

Pass a non-nil sentinel via `null_value` when dynamic data must distinguish
explicit `null` from absence:

```titan
local json = import "json"
local io = import "io"

local record NullToken
end

function main(_args: {string}): integer
  local token = NullToken()
  local values: {value} = json.decode("[1,null,null]", nil,
    json.DecodeOption.null_value(token))
  io.print(#values, json.encode(values, json.EncodeOption.null_value(token)))
  return 0
end
```

The encoder matches the sentinel with raw value equality before ordinary type
dispatch; reuse the same token on both sides. A dedicated empty record avoids
collisions with application data (`false`, `0`, or `""` work as tokens, but also
replace equal real values, including `0` and `0.0`). Passing `NaN` raises
`invalid_option`; passing `nil` restores the default. Sentinels never rewrite
object keys or union discriminators.

Sentinels apply only to dynamic decoding and `is_value` schema positions:

- Explicit `nil` and Option targets decode `null` as `nil`.
- Concrete Array elements and Map values decode `null` as an absent entry rather
  than storing a foreign sentinel.
- Required scalars, record fields, root nominals, and non-optional union parts
  reject `null`.
- Missing nil-admitting record fields and union parts become `nil`, never the
  sentinel.

## Typed schemas: records and containers

Request a nominal target with
`reflect.Type.is_named(reflect.NamedType("module.Type"))`. The defining module
must already be initialized; `json.decode` does not import modules and raises
`unknown_type` for unregistered names.

Build structural schemas with `reflect.Type` constructors (`Type.is_array` takes
constness before the element descriptor; `Type.is_map` takes key then value):

```titan
local json = import "json"
local reflect = import "reflect"

function read_integers(text: string): {integer}
  local schema = reflect.Type.is_array(
    reflect.ArrayTypeConstness.is_mutable(), reflect.Type.is_integer())
  return json.decode(text, schema)
end
```

Automatic record decoding validates every member and calls the record's public
`new` constructor once. Both the compiler-synthesized constructor and custom
overrides work, provided `new` has fixed parameters, no flexible result tail,
and a single result of the target record type; otherwise decoding raises
`constructor_unavailable` before invoking `new`.

JSON member names and schemas follow the constructor's parameters:

- Missing members are allowed only for parameters whose type admits `nil`
  (`nil`, Option, or `value`). A required `boolean` cannot be omitted.
- Extra members raise `unknown_field` unless
  `DecodeOption.ignore_unknown_fields(true)` is set. Ignored members undergo
  syntax and resource validation.
- A record with `local` fields has no public synthesized constructor; it can be
  decoded automatically only if it defines a compatible public `new`. Encoding
  its public fields works either way.

Recursive nominal schemas resolve lazily as values are traversed. Generic type
arguments are erased at runtime: `Box<|Person|>` and `Box<|string|>` share the
same nominal schema, and erased type parameters decode dynamically as `value`.

Decoded mutable Arrays allocate `{value}` storage; typed reads check elements on
access. Const Array targets return `const {T}` Arrays, and maybe-const targets
return mutable Arrays. See [Arrays, Maps, and Iteration](arrays-maps.md).

## Tagged unions

Union values encode as JSON objects carrying the public variant name under a
discriminator key (default `"tag"`) and each payload part under its declared
name. A single unnamed payload such as `count(integer)` uses the key `"value"`:

| Variant declaration and value | JSON |
| --- | --- |
| `idle()` · `Message.idle()` | `{"tag":"idle"}` |
| `count(integer)` · `Message.count(3)` | `{"tag":"count","value":3}` |
| `optional(string?)` · `Message.optional(nil)` | `{"tag":"optional","value":null}` |
| `text(message: string)` · `Message.text("hi")` | `{"tag":"text","message":"hi"}` |
| `point(x: integer, y: integer)` · `Message.point(2, 3)` | `{"tag":"point","x":2,"y":3}` |

Each payload part keeps its own JSON representation; a nested record or Map
stays an object under that part's key.

Typed union decoding accepts keys in any order. Missing nil-admitting parts
become `nil`; other missing parts raise `missing_field`. Unknown keys in a union
object are always rejected, even with `ignore_unknown_fields(true)`. Encoding an
active `local` variant raises `private_variant`; decoding an unrecognized arm
raises `unknown_variant`.

Select an alternate discriminator with matching `EncodeOption.tag_field` and
`DecodeOption.tag_field` options, which apply to every nested union in that
call. If the discriminator collides with a declared part name of the active
variant, both encoding and decoding raise `invalid_union`. Without a union
schema, an object containing `"tag"` decodes as an ordinary Map.

## Strings and numbers

Decoding enforces strict [RFC 8259](https://www.rfc-editor.org/rfc/rfc8259.html)
syntax for one complete document (whitespace is space, tab, CR, or LF).
Comments, trailing commas, trailing data, malformed numbers or escapes, raw
control bytes, a leading UTF-8 BOM, and duplicate object keys (including after
`\u` decoding, such as `"a"` and `"\u0061"`) are rejected.

Strings must be valid UTF-8. Escaped surrogate pairs decode to their Unicode
scalar value, lone surrogates and invalid UTF-8 raise `invalid_utf8`, and
embedded NUL bytes round-trip as `\u0000`. Encoding also rejects invalid UTF-8
byte strings.

Numeric conversion preserves Titan's integer/float distinction without modifying
the process locale:

- Dynamic decoding turns integer-form tokens into exact 64-bit integers (raising
  on overflow) and tokens with a fraction or exponent into finite floats.
- An integer schema accepts exact, in-range decimal values such as `1.0` or
  `1e3`, checked directly in decimal so integers above 2^53 do not round.
- A float schema allows normal floating-point rounding, rejects overflow and
  nonzero underflow to zero, and preserves `-0.0`.
- Integral floats encode with a decimal point or exponent so dynamic decoding
  recovers them as floats. Non-finite floats (`NaN`, `±inf`) cannot be encoded.
- Full-range 64-bit integers emit as JSON numbers.

## Diagnostics and limits

```text
record Error
  const code: string
  const message: string
  const position: integer?
  const line: integer?
  const column: integer?
  const path: string
end
```

Catch `json.Error` to handle malformed input, schema mismatches, or budget
exhaustion while letting unrelated runtime errors propagate:

```titan
local json = import "json"
local reflect = import "reflect"
local io = import "io"

function try_parse_port(text: string): integer?
  local n: integer = json.decode(text, reflect.Type.is_integer())
  return n
catch
  if not (error is json.Error) then raise end
  local err: json.Error = error
  io.print(err.code, err.path, err.message)
  return nil
end
```

`code` is a stable error label (such as `expected_value`,
`expected_array_separator`, `trailing_input`, `duplicate_key`, `invalid_utf8`,
`unknown_field`, `limit_exceeded`). `position` is a 1-based byte offset (`#source + 1`
at EOF), and `line`/`column` follow `peg.line_column` (CRLF counts as one line
ending; CR and LF also work). These three fields are `nil` for encoding and
option errors. `path` starts at `$`, with quoted keys and 1-based Array indices
(for example `$["people"][2]["name"]`); syntax errors report `$`.

Default resource budgets are **16 MiB** of input or output text, **1,000,000**
visited JSON values, and a container nesting depth of **32**. `max_depth`,
`max_bytes`, and `max_nodes` accept positive integers up to
[`math.maxinteger`](standard-library-math.md). Depth counts nested JSON
containers (a root Array, object, or union envelope has depth 1). Node counts
include the root, nulls, generated union tags, and ignored record members.
Exceeding any budget raises `limit_exceeded`.

The depth budget bounds JSON container nesting, not underlying engine stack.
Decoding parses with [`titan.peg`](standard-library-peg.md) and does not alter
the shared PEG matching stack; call `peg.set_max_stack` when processing deeply
nested sibling structures.

See [JSON implementation](../implementation/json-library.md) for parser and
allocation internals.
