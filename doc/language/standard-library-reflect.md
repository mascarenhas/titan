# Reflection standard library

The `titan.reflect` module provides runtime type and value reflection for Titan programs:

```titan
local reflect = import "reflect"
```

Lua programs load the module using `require "titan.reflect"`.

Reflection enables dynamic inspection of values, queries into nominal types
(records, unions, and interfaces), runtime type resolution, and field-level
get/set operations on records and interfaces with full garbage-collection safety.

## Inspecting values

The primary entry point for value inspection is `inspect`:

```titan
function inspect(v: value): Value
```

`inspect` examines the runtime tag, metatable, and user value slots of any Titan
or Lua value, returning a `Value` tagged union.

### The `Value` union

```titan
union Value
  is_nil
  is_integer: integer
  is_float: float
  is_boolean: boolean
  is_string: string
  is_array: ArrayValue
  is_const_array: ConstArrayValue
  is_map: MapValue
  is_record: RecordValue
  is_union: UnionValue
  is_interface: InterfaceValue
  is_titan_function: TitanFunctionValue
  is_lua_function: LuaFunctionValue
  is_lua_c_function: LuaCFunctionValue
  is_owned_foreign_pointer: OwnedForeignPointerValue
  is_owned_foreign_array: OwnedForeignArrayValue
  is_lua_userdata: LuaUserdataValue
  is_lua_thread: LuaThreadValue
  is_raw_pointer: *void
end
```

Values are unpacked using Titan's `case` statement:

```titan
local v = reflect.inspect(obj)
case v
when is_integer: n then
  print("Integer: " .. str.tostring(n))
when is_record: rv then
  print("Record: " .. rv.descriptor.name)
when is_union: uv then
  print("Union: " .. uv.descriptor.name .. " tag " .. str.tostring(uv.tag))
else
  print("Other value")
end
```

### Container values

Arrays and maps wrap their underlying containers:

```titan
record ArrayValue
  const val: { value }
end

record ConstArrayValue
  const val: const { value }
end

record MapValue
  const val: { value: value }
end
```

### Record reflection

A `RecordValue` provides access to a record's runtime fields and public schema:

```titan
record RecordValue
  const n_fields: integer
  const val: value
  const descriptor: RecordType
end

function RecordValue:get(i: integer): value
function RecordValue:set(i: integer, v: value)
```

- `n_fields`: total number of fields in the record.
- `descriptor`: static type descriptor (`RecordType`), including field names,
  types, and modifiers.
- `rv:get(i)`: reads the 1-based field at index `i` (matching `descriptor.fields[i]`).
  Raises a runtime error if `i` is out of bounds (`i < 1` or `i > n_fields`).
- `rv:set(i, v)`: writes value `v` to field `i`. Raises a runtime error if:
  - `i` is out of bounds;
  - field `i` is declared `const`;
  - the type of `v` is incompatible with the field's declared type.
  Writing a collectable object through `rv:set` triggers Lua's GC write barrier
  (`luaC_barrierback`), ensuring the referenced object remains rooted and safe
  from premature garbage collection.

### Union reflection

A `UnionValue` exposes the active variant tag, optional payload, and descriptor:

```titan
record UnionValue
  const tag: integer
  const payload: value
  const val: value
  const descriptor: UnionType
end
```

- `tag`: the 0-based numeric variant tag of the active arm.
- `payload`: the payload value of the variant, or `nil` if the active variant
  carries no payload.
- `descriptor`: the `UnionType` descriptor containing all declared variants.
  The matching variant can be indexed as `descriptor.variants[tag + 1]`.

### Interface reflection

An `InterfaceValue` provides access to an interface view, its wrapped concrete
instance, and its captured const fields:

```titan
record InterfaceValue
  const n_fields: integer
  const val: value
  const wrapped: value
  const descriptor: InterfaceType
end

function InterfaceValue:get(i: integer): value
```

- `n_fields`: number of fields defined on the interface.
- `wrapped`: the underlying concrete record or union instance.
- `descriptor`: the `InterfaceType` descriptor listing fields and methods.
- `iv:get(i)`: reads the 1-based captured const field at index `i`.
  Raises a runtime error if `i < 1` or `i > n_fields`.

### Function reflection

Functions are partitioned into three variants:

```titan
record TitanFunctionValue
  const val: (...: value) -> (...: value)
  const native_entry: *void
  const lua_entry: *void
  const descriptor: FunctionType
end

record LuaFunctionValue
  const val: (...: value) -> (...: value)
  const descriptor: LuaFunctionType
end

record LuaCFunctionValue
  const val: (...: value) -> (...: value)
  const entry: *void
end
```

`TitanFunctionValue.lua_entry` exposes the function's C entry point callable from
the Lua C API.

## Nominal type registry

Titan nominal types (records, unions, interfaces) registered across compiled modules
can be looked up by their fully-qualified names:

```titan
function find_nominal(name: string): NominalType?
function record_descriptor(name: string): RecordType?
function union_descriptor(name: string): UnionType?
function interface_descriptor(name: string): InterfaceType?
```

`find_nominal` returns a `NominalType` union:

```titan
union NominalType
  is_record: RecordType
  is_union: UnionType
  is_interface: InterfaceType
end
```

If the requested type is not registered, each function returns `nil`.

## Type descriptors

Type descriptors model Titan's static type system at runtime.

### The `Type` union

```titan
union Type
  is_nil
  is_boolean
  is_integer
  is_float
  is_string
  is_value
  is_named: NamedType
  is_array: ArrayType
  is_map: MapType
  is_record: RecordType
  is_union: UnionType
  is_interface: InterfaceType
  is_option: Type
  is_function: FunctionType
  is_foreign_function: ForeignFunctionType
  is_owned_foreign_pointer: OwnedForeignPointerType
  is_owned_foreign_array: OwnedForeignArrayArray
  is_foreign_void
  is_foreign_integer: ForeignIntegerType
  is_foreign_float: ForeignFloatType
  is_foreign_pointer: ForeignPointerType
  is_foreign_array: ForeignArrayType
  is_foreign_struct: ForeignStructType
  is_foreign_union: ForeignUnionType
  is_foreign_typedef: ForeignTypedefType
end
```

### Resolving named types

When a type descriptor references a nominal type by name, it appears as an
`is_named: NamedType` variant. A `NamedType` can be resolved into its underlying
record, union, or interface type descriptor:

```titan
record NamedType
  const name: string
end

function NamedType:resolve(): Type
```

`resolve()` looks up the nominal registry and returns the matching `is_record`,
`is_union`, or `is_interface` type descriptor. The lookup result is cached internally
for subsequent calls. If the nominal type is unknown, `resolve()` returns `Type.is_value()`.

### Descriptors for records, unions, and interfaces

```titan
record RecordType
  const name: string
  const fields: const { FieldType }
  const statics: const { StaticFunctionType }
  const methods: const { MethodType }
end

record UnionType
  const name: string
  const variants: const { VariantType }
  const statics: const { StaticFunctionType }
  const methods: const { MethodType }
end

record InterfaceType
  const name: string
  const fields: const { FieldType }
  const methods: const { MethodType }
end
```

Field and variant details:

```titan
record FieldType
  const name: string
  const index: integer
  const descriptor: Type
  const is_const: boolean
end

record VariantType
  const name: string
  const tag: integer
  const descriptor: Type?
  const callable: (value) -> value
end
```
