# Reflection standard library

`titan.reflect` inspects Titan and Lua values at runtime, queries registered
nominal schemas, reads and writes public record or Interface fields, and
constructs nominal values dynamically. Reflection queries only types already
initialized in the current Lua state and does not import modules.

- **Import:** `local reflect = import "reflect"` (Titan) · `require "titan.reflect"` (Lua)
- **Targets:** Native & Browser (complete; synchronous)

## Quick example

Walk the public fields of any record or Interface value dynamically:

```titan
local reflect = import "reflect"
local strings = import "string"
local io = import "io"

record ServiceConfig
  const host: string
  port: integer
  tls: boolean
end

function format_public_fields(candidate: value): string
  local writer = strings.writer()
  case reflect.inspect(candidate)
  when is_record(rec) then
    writer:write(rec.type.name .. "{")
    for i = 1, rec.n_fields do
      if i > 1 then writer:write(", ") end
      local field = rec.type.fields[i]
      writer:write(field.name .. "=" .. strings.tostring(rec:get(i)))
    end
    writer:write("}")
  when is_interface(iface) then
    writer:write(iface.type.name .. "{")
    for i = 1, iface.n_fields do
      if i > 1 then writer:write(", ") end
      local field = iface.type.fields[i]
      writer:write(field.name .. "=" .. strings.tostring(iface:get(i)))
    end
    writer:write("}")
  else
    writer:write(strings.tostring(candidate))
  end
  return writer:drain()
end

function main(_args: {string}): integer
  local cfg = ServiceConfig("localhost", 8443, true)
  io.print(format_public_fields(cfg))
  return 0
end
```

## Inspecting values

```text
function inspect(v: value): Value
```

`inspect` returns a 19-variant tagged union `Value` preserving exact runtime
tags: `3` produces `is_integer`, while `3.0` produces `is_float`.

| Variant | Payload parts |
| --- | --- |
| `is_nil` | *(none)* |
| `is_integer`, `is_float`, `is_boolean`, `is_string` | `value` of the corresponding scalar type |
| `is_array` | `value: {value}` |
| `is_const_array` | `value: const {value}` |
| `is_map` | `value: {value: value}` |
| `is_record` | `value: RecordValue` |
| `is_union` | `value: UnionValue` |
| `is_interface` | `value: InterfaceValue` |
| `is_titan_function` | `value`, `native_entry`, `lua_entry`, `type` |
| `is_lua_function` | `value`, `type` |
| `is_lua_c_function` | `value`, `entry` |
| `is_owned_foreign_pointer` | `value`, `payload`, `size`, `type` |
| `is_owned_foreign_array` | `value`, `payload`, `size`, `count`, `type` |
| `is_lua_userdata` | `value: value` |
| `is_lua_thread` | `value: value`, `thread: foreign *lua_State` |
| `is_raw_pointer` | `value: foreign *void` |

Dispatch with `case`. `Value` describes a runtime value; the separate `Type`
union describes static schemas.

### Containers and opaque values

`is_array`, `is_const_array`, and `is_map` carry the original container directly
as `{value}`, `const {value}`, and `{value: value}` without copying or
recovering erased element types. Any Lua table (with or without a metatable)
classifies as `is_map`.

`is_lua_userdata` retains unrecognized full userdata in `value`. `is_lua_thread`
retains a Lua thread in `value` and exposes its `foreign *lua_State` in
`thread`. Ordinary C object and function pointers cross `value` as light
userdata and classify as `is_raw_pointer`, carrying no pointee type, signature,
or ownership information.

### Records

```text
record RecordValue
  const n_fields: integer
  const value: value
  const type: RecordType
end

function RecordValue:get(i: integer): value
function RecordValue:set(i: integer, v: value)
function RecordValue:project(i: integer): value
```

`value` holds the original record and `n_fields` counts its **public** fields
(`#record_value.type.fields`). `get(i)` and `set(i, v)` index the 1-based public
field list `record_value.type.fields[i]` and reject indices outside
`1..n_fields`. Local fields are omitted and can create gaps in the separate
0-based `FieldType.index`; always pass the 1-based public ordinal to `get` and
`set`, never `FieldType.index`.

`get` boxes the field value; native numeric fields check conversion on read, and
embedded C aggregates/arrays return borrowed raw pointers following the
[FFI embedded-storage lifetime rules](ffi.md). `set` rejects `const` fields and
applies target-directed dynamic conversion (matching a Lua write—for example,
integral floats convert to `integer`, while fractional floats fail without
modifying the field). See [types](types.md) for boundary rules.
Writes update the original record in place and run the GC write barrier
automatically.

```titan
local reflect = import "reflect"

record Counter
  total: integer
end

function increment(counter: Counter, amount: integer): integer
  case reflect.inspect(counter)
  when is_record(rec) then
    local total: integer = rec:get(1)
    rec:set(1, total + amount)
    return counter.total
  else
    raise "expected a record"
  end
end
```

### Unions

```text
record UnionValue
  const tag: integer
  const n_parts: integer
  const value: value
  const type: UnionType
end

function UnionValue:get(i: integer): value
function UnionValue:project(i: integer): value
```

`tag` is the active variant's 0-based runtime tag, and `n_parts` is its payload
part count (including `nil` parts: an empty variant has `0` parts, while a
one-part variant holding `nil` has `1`). `get(i)` takes a 1-based part index in
`1..n_parts`, boxes ordinary values, and returns borrowed pointers for embedded
C aggregates or fixed arrays. `value` keeps the union and its parts reachable.

`UnionValue.type.variants` lists public variants in declaration order. Public
variants occupy the dense 0-based tag range ahead of all `local` variants, even
when private variants appear interleaved in source. Match `UnionValue.tag`
against `VariantType.tag` to find the schema; an active `local` variant has no
entry in `variants`, though its `tag`, `n_parts`, and `get(i)` values are
observable.

### Native storage projections and default construction

```text
function RecordType:construct(fields: const {value}): value
function UnionType:construct(tag: integer, parts: const {value}): value
```

`project(i)` uses the same 1-based ordinal as `get(i)` and returns a lossless
representation for supported native C storage:

- Ordinary Titan values return unchanged.
- C integers return as Titan `integer` preserving all bit patterns (unsigned
  64-bit values above `INT64_MAX` project as negative `integer`s).
- C `float` and `double` become Titan `float`; C `long double` becomes exact C
  hexadecimal text (`%La`) using the current process locale (reconstructed with
  `strtold`).
- Pointers project as raw light-userdata pointers (including `NULL`), without
  traversing or retaining pointees.
- Complete C structs and fixed C arrays project recursively as `const {value}`
  Arrays of fields/elements without reading padding bytes. Named C bitfields
  participate in field order and range-check on reconstruction.
- C unions, flexible array members, and integers wider than 64 bits raise.

`RecordType:construct` and `UnionType:construct` allocate and initialize fresh
nominal values directly from projected field or part lists without calling
user-defined `new` (so `const` fields initialize directly). Records containing
`local` fields cannot be constructed this way, and `UnionType:construct` accepts
only public tags. Arguments follow field/part order; trailing `nil` positions
may be omitted from the Array length. Excess items, missing required values,
type mismatches, or out-of-range native numbers raise without exposing partial
objects.

`RecordType.is_public` and `UnionType.is_public` report type visibility, while
`all_public` reports whether every field or variant is public. A `local` record
can have `all_public == true`, so serializers check both flags as needed.

### Interfaces

```text
record InterfaceValue
  const n_fields: integer
  const value: value
  const wrapped: value
  const type: InterfaceType
end

function InterfaceValue:get(i: integer): value
```

`value` is the Interface wrapper (pass it as the receiver to `MethodType.callable`),
and `wrapped` is the underlying concrete record or union (suitable for a
separate `inspect`). `get(i)` reads the captured `const` field at
`type.fields[i]` using 1-based indexing. Interfaces have no reflection setter.

### Functions

Every function variant carries a callable `value` part of type
`function(...: value): (...: value)` honoring ordinary dynamic argument and
result adjustment:

| Variant | Additional payload parts |
| --- | --- |
| `is_titan_function` | `native_entry: foreign *void`, `lua_entry: foreign function(*lua_State): int`, `type: FunctionType` |
| `is_lua_function` | `type: LuaFunctionType` |
| `is_lua_c_function` | `entry: foreign function(*lua_State): int` |

Bind only the parts you need; alias `type` since it is a reserved word:

```titan
local reflect = import "reflect"

function fixed_parameter_count(candidate: value): integer
  case reflect.inspect(candidate)
  when is_titan_function { signature = type } then
    return #signature.param_descriptors
  else
    raise "expected a Titan function"
  end
end
```

```text
record LuaFunctionType
  const source: string
  const short_source: string
  const line_defined: integer
  const last_line_defined: integer
  const what: string
  const is_vararg: boolean
  const n_params: integer
end
```

`LuaFunctionType` exposes Lua debug metadata for Lua functions. Both Lua C
closures and light C functions classify as `is_lua_c_function`. Calling raw
`lua_entry`, `entry`, or `native_entry` pointers requires the
[FFI and Lua C API contracts](ffi.md).

### Owned C storage

```text
-- Payload parts inside Value:
is_owned_foreign_pointer(value: value, payload: foreign *void,
                         size: integer, type: OwnedForeignPointerType)
is_owned_foreign_array(value: value, payload: foreign *void,
                       size: integer, count: integer,
                       type: OwnedForeignArrayType)
```

`size` gives storage size in bytes; owned Arrays also report element `count`.
`value` retains the GC-managed owner, and `payload` borrows its raw address;
keep `value` live while accessing `payload`.

## Nominal lookup and resolution

```text
record NamedType
  const name: string
end

union NominalType
  is_record(value: RecordType)
  is_union(value: UnionType)
  is_interface(value: InterfaceType)
end

function find_nominal(name: string): NominalType?
function NamedType:resolve(): Type
function Type:resolve(): Type
```

`find_nominal` looks up a fully qualified nominal name (such as
`"titan.reflect.FieldType"`) among initialized modules and returns `nil` if
absent:

```titan
local reflect = import "reflect"

function public_field_count(name: string): integer?
  local found? = reflect.find_nominal(name)
  if found == nil then return nil end
  case found
  when is_record(descriptor) then
    return #descriptor.fields
  when is_interface(descriptor) then
    return #descriptor.fields
  else
    return nil
  end
end
```

Nominal references nested inside descriptors appear as `Type.is_named(NamedType)`.
`NamedType:resolve()` returns `Type.is_record`, `Type.is_union`, or
`Type.is_interface`, falling back to `Type.is_value()` when unregistered.
Repeated lookups of a registered name reuse a cached descriptor, whereas misses
are never cached (so a module initialized later resolves on the next call).
`Type` values have no identity contract: inspect them with `case` rather than
comparing with `==` or using them as Map keys.

`Type:resolve()` resolves `is_named` and `is_foreign_named` receivers by one
step and returns every other `Type` unchanged without recursively expanding
nested schemas.

## Type descriptors

```text
union ArrayTypeConstness
  is_mutable()
  is_const()
  is_maybe_const()
end

union Type
  is_nil()
  is_boolean()
  is_integer()
  is_float()
  is_string()
  is_value()
  is_named(value: NamedType)
  is_array(is_const: ArrayTypeConstness, elem_descriptor: Type)
  is_map(key_descriptor: Type, value_descriptor: Type)
  is_record(value: RecordType)
  is_union(value: UnionType)
  is_interface(value: InterfaceType)
  is_option(value: Type)
  is_function(value: FunctionType)
  is_foreign_function(param_descriptors: const {Type},
                      is_vararg: boolean,
                      return_descriptor: Type)
  is_owned_foreign_pointer(value: OwnedForeignPointerType)
  is_owned_foreign_array(value: OwnedForeignArrayType)
  is_foreign_void()
  is_foreign_named(value: ForeignNamedType)
  is_foreign_integer(spelling: string, is_signed: boolean,
                     rank: integer, bits: integer)
  is_foreign_float(spelling: string)
  is_foreign_pointer(pointee_descriptor: Type, quals: const {string})
  is_foreign_array(elem_descriptor: Type, len: value, quals: const {string})
  is_foreign_struct(value: ForeignStructType)
  is_foreign_union(value: ForeignUnionType)
  is_foreign_typedef(name: string, target_descriptor: Type,
                     quals: const {string})
end
```

### Containers and callable signatures

```text
record FunctionType
  const param_descriptors: const {Type}
  const vararg_descriptor: Type?
  const return_descriptors: const {Type}
  const flexret_descriptor: Type?
end
```

`Type.is_array` pairs an `ArrayTypeConstness` (`is_mutable`, `is_const`, or
`is_maybe_const`) with `elem_descriptor`. `Type.is_map` pairs `key_descriptor`
and `value_descriptor`, and `Type.is_option` wraps its non-nil base descriptor.

In `FunctionType`, `nil` for `vararg_descriptor` or `flexret_descriptor` means
fixed arity on that side. An empty `return_descriptors` with `nil`
`flexret_descriptor` describes a zero-result function, not a single `nil`
result. `Type.is_foreign_function` carries `param_descriptors`, `is_vararg`, and
one `return_descriptor` (which may be `is_foreign_void`).

### Public nominal members

```text
record RecordType
  const name: string
  const is_public: boolean
  const all_public: boolean
  const fields: const {FieldType}
  const statics: const {StaticFunctionType}
  const methods: const {MethodType}
end

record UnionType
  const name: string
  const is_public: boolean
  const all_public: boolean
  const variants: const {VariantType}
  const statics: const {StaticFunctionType}
  const methods: const {MethodType}
end

record InterfaceType
  const name: string
  const fields: const {FieldType}
  const methods: const {MethodType}
end

record FieldType
  const name: string
  const index: integer
  const type: Type
  const is_const: boolean
end

record VariantPartType
  const name: string
  const type: Type
end

record VariantType
  const name: string
  const tag: integer
  const parts: const {VariantPartType}
  const callable: function(...: value): value
end

record MethodType
  const name: string
  const param_names: const {string}
  const param_descriptors: const {Type}
  const vararg_descriptor: Type?
  const return_descriptors: const {Type}
  const flexret_descriptor: Type?
  const callable: function(value, ...: value): (...: value)
end

record StaticFunctionType
  const name: string
  const param_names: const {string}
  const param_descriptors: const {Type}
  const vararg_descriptor: Type?
  const return_descriptors: const {Type}
  const flexret_descriptor: Type?
  const callable: function(...: value): (...: value)
end

function RecordType:public_constructor(): StaticFunctionType?
```

Local fields, variants, methods, and statics are omitted from descriptors.
Public fields and variants follow declaration order; record and union `methods`
and `statics` are sorted by name, while Interface `methods` follow declaration
order.

`MethodType.callable` accepts the inspected `value` as its first argument;
`param_names` and `param_descriptors` describe the remaining declared arguments.
`StaticFunctionType.callable` takes ordinary arguments, and
`VariantType.callable` constructs that variant from arguments ordered by `parts`
(single unnamed parts use the name `"value"`). All reflected callables enforce
ordinary dynamic argument and result checks.

`RecordType:public_constructor()` locates the public static `new` without
invoking it, returning its descriptor only when it has fixed parameters, no
flexible result tail, and a single result of that record type (otherwise `nil`).
Its parameter names and types need not match field names; JSON uses this
signature for named decoding, while portable protobuf additionally requires
parameter names to match public fields when decoding records with `local`
fields.

### Erased generics

Reflection reports the shared erased runtime schema of a generic declaration:
`Box<|integer|>` and `Box<|string|>` share the nominal name `module.Box`.

- An unconstrained type parameter erases to `Type.is_value()`.
- An Interface-constrained parameter appears as `Type.is_named` for the outer
  constraint Interface (with its own generic arguments erased); call `:resolve()`
  to obtain the `is_interface` descriptor.
- Surrounding container, Option, and callable structure is preserved (`{T}`
  becomes an Array of `is_value`, while an unconstrained `T?` collapses to
  `is_value`).

### C type details

```text
record OwnedForeignPointerType
  const pointee_descriptor: Type
end

record OwnedForeignArrayType
  const elem_descriptor: Type
end

record ForeignNamedType
  const name: string
end

record ForeignFieldType
  const name: string
  const type: Type
  const bitfield: value
  const is_flexible_array: boolean
end

record ForeignStructType
  const cname: string
  const tagname: string
  const typedef: string
  const fields: const {ForeignFieldType}
  const is_complete: boolean
  const has_fam: boolean
end

record ForeignUnionType
  const cname: string
  const tagname: string
  const typedef: string
  const fields: const {ForeignFieldType}
  const is_complete: boolean
end

function ForeignNamedType:resolve(): Type
```

`is_foreign_integer` exposes `spelling`, `is_signed`, `rank`, and `bits`;
`is_foreign_float` exposes `spelling`. `is_foreign_pointer` and
`is_foreign_array` carry qualifier arrays (`quals`), and arrays also report
`len`. `ForeignStructType` and `ForeignUnionType` report C tag/typedef names,
fields, completeness, and flexible-array presence (`has_fam`).
`is_foreign_typedef` exposes `name`, `target_descriptor`, and `quals`. Public
exportability follows the [FFI export rules](ffi.md).

Recursive C declarations break cycles with `Type.is_foreign_named(ForeignNamedType)`.
Calling `ForeignNamedType:resolve()` (or `Type:resolve()`) resolves one step to
the retained struct, union, or typedef descriptor, keeping the underlying
foreign declaration alive across garbage collections. Unlike
`NamedType:resolve()`, an unknown C declaration key raises
`unknown foreign type <name>`.

See [Reflection implementation](../implementation/standard-library-reflect.md)
for metadata hydration and accessor caching internals.
