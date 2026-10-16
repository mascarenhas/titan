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

| Variant | Named payload parts |
| --- | --- |
| `is_nil` | none |
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

Use `case` to select the variant. `Value` describes the value's representation;
the separate `Type` union describes its schema where one is available.

### Containers and opaque values

`is_array`, `is_const_array`, and `is_map` carry the original container
directly as `{value}`, `const {value}`, and `{value: value}`, respectively.
Inspection does not copy the container or recover erased element type
arguments. A Lua table is classified as a Map, including one with a metatable.

`is_lua_userdata` retains an unrecognized full userdata object in its `value`
part. `is_lua_thread` retains a Lua thread in `value`, and its `thread` part exposes
its `foreign *lua_State` address. An ordinary C object or function pointer crosses
through `value` as lightuserdata and produces `is_raw_pointer`; its address
carries no pointee-type, C-signature, or ownership information.

### Records

The public fields and operations of `RecordValue` are:

```text
const n_fields: integer
const value: value
const type: RecordType

function RecordValue:get(i: integer): value
function RecordValue:set(i: integer, v: value)
function RecordValue:project(i: integer): value
```

`value` retains the original record. `n_fields` is the number of **public**
fields, equal to `#record_value.type.fields` for an inspected `record_value`.
`get(i)` and `set(i, v)` select the 1-based entry `record_value.type.fields[i]`; local fields are absent. Their presence
can leave gaps in the separate, 0-based `FieldType.index`, so do not pass that
stored index to `get` or `set`.

Both operations reject indices outside `1..n_fields`. `get` converts the field
to its boxed representation. Native numeric values are checked at that boundary;
a failed conversion leaves the field unchanged. An eligible embedded C object
projects a borrowed raw address, retaining the lifetime rules described in
[Native storage](nominal-storage.md). `set` rejects const fields and applies the
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
  const n_parts: integer
  const value: value
  const type: UnionType
end

function UnionValue:get(i: integer): value
function UnionValue:project(i: integer): value
```

`tag` is the active variant's 0-based runtime tag. `n_parts` is its payload
arity, including parts whose value is nil. `get(i)` selects the 1-based part
and rejects indices outside `1..n_parts`. It boxes ordinary parts with the
normal conversion checks; a native numeric value may fail that conversion. An
embedded C aggregate or fixed array returns its projected borrowed address,
without allocating an owned copy or Titan Array.
An empty variant has zero parts; a one-part variant containing nil still has
one. The retained `value` keeps the union and its parts alive.

The inspected union's `.type.variants` contains public variants in declaration
order. Their `VariantType.tag` values occupy the dense zero-based range before
all private variants; interleaved private declarations do not leave gaps in
the public tags. Compare an entry's `tag` with `UnionValue.tag` when finding its
schema, and account for a tag outside the public range. A private active variant
has no public variant descriptor, although inspection still exposes its
runtime tag, part count, and readable payload parts.

### Native storage projections and default construction

```text
function RecordType:construct(fields: const {value}): value
function UnionType:construct(tag: integer, parts: const {value}): value
```

`project(i)` uses the same 1-based field or payload ordinal as `get(i)`, with a
lossless representation for supported native C storage. Ordinary Titan values
are returned unchanged. A C integer becomes a Titan integer carrying all its
bits; an unsigned 64-bit value above `INT64_MAX` therefore has a negative
projection. C `float` and `double` become Titan floats. C `long double` becomes
the C library's exact hexadecimal floating text (`%La`), using the process
locale; reconstruction uses the same locale's `strtold`. Pointer projections
are raw pointers, including NULL as lightuserdata; no pointed-to storage is
traversed or retained.

A by-value C struct becomes a `const {value}` containing its fields in
declaration order, recursively projected. A fixed C array becomes a const
Array of its elements. The projection copies semantic fields and never reads
padding bytes. C unions, flexible-array storage, and integer widths above 64
bits raise when encountered. Native scalar Options preserve nil and otherwise
use the same projected representation.
Named C bitfields, including const bitfields, participate in field order;
reconstruction rejects values outside the bitfield's range.

`construct` initializes a fresh nominal value from those projections using the
compiler's default storage construction. It can initialize const fields and
does not call a user-defined `new`. A record with private fields cannot be
constructed this way. Union construction accepts only a public variant tag.
Argument positions follow the descriptor's field or part order; trailing nil
positions may be absent from the Array's length. Excess positions, missing
required values, incompatible types, out-of-range native scalars, and invalid
long-double text raise. Failure never exposes a partially initialized result.

`RecordType.is_public` and `UnionType.is_public` report declaration visibility.
Their `all_public` fields report whether every field or variant is public.
These are separate properties: a local record can have only public fields.
Projections and construction are general reflection operations; a serializer
can use both properties to impose its own public-data boundary.

### Interfaces

```text
const n_fields: integer
const value: value
const wrapped: value
const type: InterfaceType

function InterfaceValue:get(i: integer): value
```

`value` is the Interface wrapper, and `wrapped` is its underlying concrete
record or union. `get(i)` reads the captured const field corresponding to
the inspected Interface's `.type.fields[i]`, using 1-based indices and the same bounds rule as
record access. Interface fields have no reflection setter.

Use `value` as the receiver when invoking a method from this Interface's
descriptor. Use `wrapped` when inspecting the concrete value separately.

### Functions

All three function-value variants retain a callable `value` part with type
`function (...: value): (...: value)`. Calling it follows ordinary dynamic
callable argument and result adjustment.

| Variant | Additional parts |
| --- | --- |
| `is_titan_function` | `native_entry: foreign *void`, `lua_entry: foreign function (*lua_State): int`, `type: FunctionType` |
| `is_lua_function` | `type: LuaFunctionType` |
| `is_lua_c_function` | `entry: foreign function (*lua_State): int` |

Select just the parts you need. For example, `type` is a reserved word, so
bind it using an alias:

```titan
local reflect = import "reflect"

function fixed_parameter_count(candidate: value): integer
  case reflect.inspect(candidate)
  when is_titan_function{signature = type} then
    return #signature.param_descriptors
  else
    raise "expected a Titan function"
  end
end
```

`LuaFunctionType` contains `source`, `short_source`, `line_defined`,
`last_line_defined`, `what`, `is_vararg`, and `n_params`, as reported by Lua's
debug information. Lua C closures and light C functions both produce
`is_lua_c_function`.

Use `value` for ordinary calls. The foreign entry fields are typed Lua C API
entry points, and `native_entry` is an address without a callable Titan
signature. Using those low-level entries requires the corresponding
[FFI and Lua C API contracts](ffi.md).

### Owned C storage

```text
-- Payload declarations within Value:
is_owned_foreign_pointer(value: value, payload: foreign *void,
                         size: integer, type: OwnedForeignPointerType)
is_owned_foreign_array(value: value, payload: foreign *void,
                       size: integer, count: integer,
                       type: OwnedForeignArrayType)
```

`size` reports the payload storage size in bytes; an owned Array also reports
its element `count`. `value` retains the owner. The raw `payload` pointer borrows
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
  is_array(is_const: ArrayTypeConstness, elem_descriptor: Type)
  is_map(key_descriptor: Type, value_descriptor: Type)
  is_record(RecordType)
  is_union(UnionType)
  is_interface(InterfaceType)
  is_option(Type)
  is_function(FunctionType)
  is_foreign_function(
    param_descriptors: const { Type },
    is_vararg: boolean,
    return_descriptor: Type)
  is_owned_foreign_pointer(OwnedForeignPointerType)
  is_owned_foreign_array(OwnedForeignArrayType)
  is_foreign_void()
  is_foreign_named(ForeignNamedType)
  is_foreign_integer(spelling: string, is_signed: boolean, rank: integer, bits: integer)
  is_foreign_float(spelling: string)
  is_foreign_pointer(pointee_descriptor: Type, quals: const { string })
  is_foreign_array(elem_descriptor: Type, len: value, quals: const { string })
  is_foreign_struct(ForeignStructType)
  is_foreign_union(ForeignUnionType)
  is_foreign_typedef(name: string, target_descriptor: Type, quals: const { string })
end
```

### Containers and callable signatures

`is_array` carries `elem_descriptor` for its element and `is_const`, which
selects `ArrayTypeConstness.is_mutable`, `is_const`, or `is_maybe_const`.
`is_map` carries `key_descriptor` and `value_descriptor`. An `is_option`
directly carries the descriptor of its nonnil base.

`FunctionType` contains const Arrays `param_descriptors` and
`return_descriptors`, plus optional `vararg_descriptor` and
`flexret_descriptor`. Nil tails mean that the signature has no corresponding
variadic input or flexible output. An empty result Array with no flexible
tail means zero results, not one nil result.

Compiler metadata uses the same nil-only absence convention before hydration;
reflection does not interpret false as a missing descriptor. Array qualifiers
cross that boundary as explicit `no`, `yes`, and `maybe` tags and become the
corresponding `ArrayTypeConstness` variants.

`is_foreign_function` instead carries `param_descriptors`, `is_vararg`, and
one `return_descriptor`, which may be `is_foreign_void`.

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
  const callable: function (...: value): (value)
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

Pass the corresponding inspected `value` as the first argument of a method
callable. A static callable takes only its ordinary arguments. A variant
callable constructs that variant. Its `parts` Array describes each payload
name and type in declaration order; an empty Array means an empty variant.
Pass arguments in that order. An unnamed source payload has the name `value`. Calls
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

`is_foreign_integer` carries `spelling`, `is_signed`, `rank`, and `bits`;
`is_foreign_float` carries `spelling`. These are target-dependent C types,
distinct from Titan's `integer` and `float`.

C struct and union descriptors report their C names, typedef spelling,
`fields`, and completeness; structs additionally report `has_fam`. Each
`ForeignFieldType` supplies `name`, `type`, `bitfield`, and
`is_flexible_array`. `is_foreign_typedef` supplies `name`,
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
