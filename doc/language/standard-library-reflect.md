# Reflection standard library

`titan.reflect` inspects runtime values, describes registered nominal types,
and reads or writes public fields dynamically:

```titan
local reflect = import "reflect"

record Counter
  total: integer
end

function increment(counter: Counter, amount: integer): integer
  local inspected = reflect.inspect(counter)
  case inspected
  when is_record(record_value) then
    local total: integer = record_value:get(1)
    record_value:set(1, total + amount)
    return counter.total
  else
    raise "expected a record"
  end
end
```

Lua programs load the same module with `require "titan.reflect"`. Reflection
describes values and types already available in the current Lua state; looking
up a name does not import its module.

## Inspecting values

```text
function inspect(v: value): Value
```

`inspect` returns a tagged union with 19 variants. It preserves the runtime
distinction between integers and floats: `3` is an `is_integer`, while `3.0`
is an `is_float`.

| Variant | Payload |
| --- | --- |
| `is_nil` | none |
| `is_integer` | `integer` |
| `is_float` | `float` |
| `is_boolean` | `boolean` |
| `is_string` | `string` |
| `is_array` | `ArrayValue` |
| `is_const_array` | `ConstArrayValue` |
| `is_map` | `MapValue` |
| `is_record` | `RecordValue` |
| `is_union` | `UnionValue` |
| `is_interface` | `InterfaceValue` |
| `is_titan_function` | `TitanFunctionValue` |
| `is_lua_function` | `LuaFunctionValue` |
| `is_lua_c_function` | `LuaCFunctionValue` |
| `is_owned_foreign_pointer` | `OwnedForeignPointerValue` |
| `is_owned_foreign_array` | `OwnedForeignArrayValue` |
| `is_lua_userdata` | `LuaUserdataValue` |
| `is_lua_thread` | `LuaThreadValue` |
| `is_raw_pointer` | `*void` |

Use `case` to select the variant. `Value` describes the value's representation;
the separate `Type` union describes its schema where one is available.

### Containers and opaque values

`ArrayValue.val`, `ConstArrayValue.val`, and `MapValue.val` expose the original
container as `{value}`, `const {value}`, and `{value: value}`, respectively.
Inspection does not copy the container or recover erased element type
arguments. A Lua table is classified as a Map, including one with a metatable.

`LuaUserdataValue.val` retains an unrecognized full userdata object.
`LuaThreadValue.val` retains a Lua thread, and `LuaThreadValue.thread` exposes
its `*lua_State` address. An ordinary C object or function pointer crosses
through `value` as lightuserdata and produces `is_raw_pointer`; its address
carries no pointee-type, C-signature, or ownership information.

### Records

The public fields and operations of `RecordValue` are:

```text
const n_fields: integer
const val: value
const descriptor: RecordType

function RecordValue:get(i: integer): value
function RecordValue:set(i: integer, v: value)
```

`val` retains the original record. `n_fields` is the number of **public**
fields, equal to `#descriptor.fields`. `get(i)` and `set(i, v)` select the
1-based entry `descriptor.fields[i]`; local fields are absent. Their presence
can leave gaps in the separate, 0-based `FieldType.index`, so do not pass that
stored index to `get` or `set`.

Both operations reject indices outside `1..n_fields`. `get` returns the field
in its normal boxed representation. `set` rejects const fields and applies the
same target-directed conversion as a Lua write to the declared field. For
example, an integral float can be written to an integer field, but a
fractional float cannot. Conversion failure leaves the field unchanged.
Options accept nil according to their declared type; nominal fields retain
their ordinary record, union, or Interface checks. See
[type conversions](types.md) for the complete boundary rules.

Writes update the original record. The implementation keeps the receiver and
new collectable value reachable and applies the required garbage-collector
write barrier. Callers do not need a separate GC operation around field access.

### Unions

```text
record UnionValue
  const tag: integer
  const payload: value
  const val: value
  const descriptor: UnionType
end
```

`tag` is the active variant's 0-based runtime tag. `payload` is the original
payload in its normal boxed representation, or nil for an empty variant.
A payload-bearing variant whose payload permits nil can also contain nil;
use its variant descriptor to distinguish those cases.

`descriptor.variants` contains public variants in declaration order. Their
`VariantType.tag` values retain the original tags, including gaps left by
private variants. Find an entry by comparing its `tag` with `UnionValue.tag`;
the tag is not an index into the descriptor Array. A private active variant
has no public variant descriptor, although inspection still exposes its
runtime tag and payload.

### Interfaces

```text
const n_fields: integer
const val: value
const wrapped: value
const descriptor: InterfaceType

function InterfaceValue:get(i: integer): value
```

`val` is the Interface wrapper, and `wrapped` is its underlying concrete
record or union. `get(i)` reads the captured const field corresponding to
`descriptor.fields[i]`, using 1-based indices and the same bounds rule as
record access. Interface fields have no reflection setter.

Use `val` as the receiver when invoking a method from this Interface's
descriptor. Use `wrapped` when inspecting the concrete value separately.

### Functions

All three function-value records retain a callable `val` with type
`function (...: value): (...: value)`. Calling it follows ordinary dynamic callable
argument and result adjustment.

| Record | Additional public fields |
| --- | --- |
| `TitanFunctionValue` | `native_entry: foreign *void`, `lua_entry: foreign function (*lua_State): int`, `descriptor: FunctionType` |
| `LuaFunctionValue` | `descriptor: LuaFunctionType` |
| `LuaCFunctionValue` | `entry: foreign function (*lua_State): int` |

`LuaFunctionType` contains `source`, `short_source`, `line_defined`,
`last_line_defined`, `what`, `is_vararg`, and `n_params`, as reported by Lua's
debug information. Lua C closures and light C functions both produce
`is_lua_c_function`.

Use `val` for ordinary calls. The foreign entry fields are typed Lua C API
entry points, and `native_entry` is an address without a callable Titan
signature. Using those low-level entries requires the corresponding
[FFI and Lua C API contracts](ffi.md).

### Owned C storage

```text
record OwnedForeignPointerValue
  const val: value
  const payload: foreign *void
  const size: integer
  const descriptor: OwnedForeignPointerType
end

record OwnedForeignArrayValue
  const val: value
  const payload: foreign *void
  const size: integer
  const count: integer
  const descriptor: OwnedForeignArrayType
end
```

`size` reports the payload storage size in bytes; an owned Array also reports
its element `count`. `val` retains the owner. The raw `payload` pointer borrows
that owner's storage and does not keep it alive by itself. Reflection does not
add a destructor or extend the lifetime of borrowed external C pointers.

## Nominal lookup and resolution

```text
function find_nominal(name: string): NominalType?

union NominalType
  is_record(RecordType)
  is_union(UnionType)
  is_interface(InterfaceType)
end

record NamedType
  const name: string
end

function NamedType:resolve(): Type
function Type:resolve(): Type
```

`find_nominal` accepts a fully qualified name, such as
`"titan.reflect.FieldType"`, and returns nil when no nominal type with that
name is registered. Select the record, union, or Interface descriptor using
`case`:

```titan
local reflect = import "reflect"

function public_field_count(name: string): integer?
  local found: reflect.NominalType? = reflect.find_nominal(name)
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

A nominal reference inside another descriptor is `Type.is_named`, carrying
its fully qualified name. `NamedType:resolve()` returns the corresponding
`Type.is_record`, `Type.is_union`, or `Type.is_interface`; an unknown name
resolves to `Type.is_value()`.

`Type:resolve()` performs that lookup when its receiver is `is_named`. An
`is_foreign_named` receiver instead resolves a retained C declaration, as
described below; other receivers are returned unchanged. This operation does
not recursively expand Array elements, field schemas, or Option contents.
Repeated nominal lookups reuse cached descriptors.

## Type descriptors

`Type` has the following 26 variants:

```text
union Type
  is_nil()
  is_boolean()
  is_integer()
  is_float()
  is_string()
  is_value()
  is_named(NamedType)
  is_array(ArrayType)
  is_map(MapType)
  is_record(RecordType)
  is_union(UnionType)
  is_interface(InterfaceType)
  is_option(Type)
  is_function(FunctionType)
  is_foreign_function(ForeignFunctionType)
  is_owned_foreign_pointer(OwnedForeignPointerType)
  is_owned_foreign_array(OwnedForeignArrayType)
  is_foreign_void()
  is_foreign_named(ForeignNamedType)
  is_foreign_integer(ForeignIntegerType)
  is_foreign_float(ForeignFloatType)
  is_foreign_pointer(ForeignPointerType)
  is_foreign_array(ForeignArrayType)
  is_foreign_struct(ForeignStructType)
  is_foreign_union(ForeignUnionType)
  is_foreign_typedef(ForeignTypedefType)
end
```

### Containers and callable signatures

`ArrayType.elem_descriptor` describes the element and `ArrayType.is_const`
selects `ArrayTypeConstness.is_mutable`, `is_const`, or `is_maybe_const`.
`MapType` has `key_descriptor` and `value_descriptor`. An `is_option`
directly carries the descriptor of its nonnil base.

`FunctionType` contains const Arrays `param_descriptors` and
`return_descriptors`, plus optional `vararg_descriptor` and
`flexret_descriptor`. Nil tails mean that the signature has no corresponding
variadic input or flexible output. An empty result Array with no flexible
tail means zero results, not one nil result.

`ForeignFunctionType` instead contains `param_descriptors`, `is_vararg`, and
one `return_descriptor`, which may be `is_foreign_void`.

### Public nominal members

```text
record RecordType
  const name: string
  const fields: const {FieldType}
  const statics: const {StaticFunctionType}
  const methods: const {MethodType}
end

record UnionType
  const name: string
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
  const descriptor: Type
  const is_const: boolean
end

record VariantType
  const name: string
  const tag: integer
  const descriptor: Type?
  const callable: function (value): (value)
end
```

These are the public fields of the descriptor records. Local record fields,
local union variants, and local methods or statics are omitted. Public fields
and variants retain declaration order; record and union method/static Arrays
are sorted by name. Interface methods retain their declaration order.

`MethodType` and `StaticFunctionType` contain `name`, `param_names`,
`param_descriptors`, `vararg_descriptor`, `return_descriptors`,
`flexret_descriptor`, and `callable`. Their fixed parameter metadata describes
the declared arguments; a method's receiver is supplied separately:

```text
MethodType.callable: function (value, ...: value): (...: value)
StaticFunctionType.callable: function (...: value): (...: value)
```

Pass the corresponding inspected `val` as the first argument of a method
callable. A static callable takes only its ordinary arguments. A variant
callable constructs that variant; its absent `descriptor` means it has no
payload, so the callable may be invoked without a payload argument. Calls
retain the ordinary checks and argument/result adjustment of the underlying
functions.

### Erased generics

Reflection reports the shared runtime schema of a generic declaration. It does
not recover a particular value's source type arguments: `Box<|integer|>` and
`Box<|string|>` share the nominal name `module.Box`.

An unconstrained type parameter appears as `Type.is_value()`. A parameter
constrained by an Interface appears as `Type.is_named` for that outer
Interface's fully qualified name. Call `:resolve()` explicitly to obtain its
`is_interface` descriptor. The constraint's generic arguments are erased;
hydration does not eagerly expand the Interface descriptor.

Surrounding Array, Map, and callable structure remains visible: for an
unconstrained `T`, `{T}` has an Array descriptor whose element is `is_value`.
An Option retains its descriptor when its erased base needs a separate nil
arm. An unconstrained `T?` instead becomes `is_value`, which already includes
nil; nested Options collapse to one Option. Generic callable descriptors
expose the same erased parameter and result shapes used at runtime.

### C type details

Owned descriptors expose `pointee_descriptor` or `elem_descriptor`. C pointer
descriptors expose `pointee_descriptor` and const qualifier names; C Array
descriptors expose `elem_descriptor`, `len`, and qualifier names.

`ForeignIntegerType` reports `spelling`, `is_signed`, `rank`, and `bits`;
`ForeignFloatType` reports `spelling`. These are target-dependent C types,
distinct from Titan's `integer` and `float`.

C struct and union descriptors report their C names, typedef spelling,
`fields`, and completeness; structs additionally report `has_fam`. Each
`ForeignFieldType` supplies `name`, `descriptor`, `bitfield`, and
`is_flexible_array`. `ForeignTypedefType` supplies `name`,
`target_descriptor`, and qualifiers. These descriptors do not make private
header-dependent C types exportable or dynamically validate an arbitrary
pointer's pointee.

Recursive C declarations use `Type.is_foreign_named` at references that would
otherwise expand a declaration again. Its `ForeignNamedType` payload exposes
`const name: string`, the compiler's qualified C declaration key.
`ForeignNamedType:resolve(): Type`, or `Type:resolve()` on that variant,
returns the corresponding retained struct, union, or typedef descriptor.
Resolution follows one named reference; it does not traverse pointer or
typedef contents. The reference retains its declaration context across later
inspections and garbage collections. An unresolved key raises
`unknown foreign type <name>`, rather than resolving to `is_value` as an
unknown Titan nominal name does.
