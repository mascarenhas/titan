---
name: titan-reflect
description: Inspect Titan values at runtime, query nominal types, resolve type descriptors, and perform dynamic field access on records and interfaces with the typed titan.reflect standard module. Use when inspecting values dynamically, introspecting records, unions, or interfaces, working with Type descriptors, or debugging Lua/Titan boundary representations.
---

# Titan reflect

Use this skill when code imports `"reflect"`/`"titan.reflect"`, inspects values
at runtime, examines type descriptors, looks up nominal types, or accesses
fields dynamically on records and interfaces. Read `titan-programmer` first; add
`titan-tester` for native reflection tests and `titan-ffi` when dealing with
function pointers or C FFI representations.

```titan
local reflect = import "reflect" -- sugar for import "titan.reflect"
```

Lua loads the compiled standard module as `require "titan.reflect"`.

## Core concepts to remember

1. **`reflect.inspect(v: value): Value` is the primary introspection entry point.**
   It maps any Titan or Lua value to an 18-variant `Value` tagged union. Unpack
   it using Titan's `case` statement.
2. **Records provide checked dynamic get/set with GC safety.**
   `RecordValue:get(i)` and `RecordValue:set(i, v)` use 1-based field indices
   corresponding to `rv.descriptor.fields[i]`. Out-of-bounds indices and writes
   to `const` fields raise runtime errors. Writes through `set` invoke the Lua
   GC write barrier to ensure collectable objects remain rooted.
3. **Unions expose tag, payload, and variant descriptor.**
   `UnionValue.tag` is the 0-based integer variant tag. `UnionValue.payload`
   is the variant payload (or `nil` for empty variants).
4. **Interfaces expose captured const fields and method dispatch.**
   `InterfaceValue:get(i)` accesses the 1-based captured const field.
   `InterfaceValue.wrapped` gives access to the underlying concrete record/union.
5. **Nominal type descriptors are queryable by fully-qualified name.**
   `find_nominal`, `record_descriptor`, `union_descriptor`, and `interface_descriptor`
   look up compiled types. `NamedType:resolve()` resolves named nominal references
   into their concrete `Type` descriptors with internal caching.

## API summary

### Inspecting values

```titan
function inspect(v: value): Value
```

Unpack with `case`:
```titan
local v = reflect.inspect(target)
case v
when is_record: rv then
  local field_val = rv:get(1)
  rv:set(1, new_val)
when is_union: uv then
  local tag = uv.tag
  local payload = uv.payload
when is_interface: iv then
  local field_val = iv:get(1)
when is_titan_function: tf then
  local c_fn = tf.lua_entry -- *void pointer to lua_CFunction entry
else
  -- other variants
end
```

### Nominal type queries

```titan
function find_nominal(name: string): NominalType?
function record_descriptor(name: string): RecordType?
function union_descriptor(name: string): UnionType?
function interface_descriptor(name: string): InterfaceType?
```

### Type resolution

```titan
function NamedType:resolve(): Type
```
