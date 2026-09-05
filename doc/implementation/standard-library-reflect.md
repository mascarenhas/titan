# Reflection library implementation

The user-facing contract is documented in the
[reflection standard-library chapter](../language/standard-library-reflect.md).
`titan.reflect` is a flat Titan standard module built against the repository's
pinned Lua 5.5 and Titan runtime FFI headers.

## Architecture and runtime type representation

Titan programs embed discoverable runtime metadata directly within metatables,
registry keys, and function closures:

1. **Brand inspection (`TITAN_BRAND`)**:
   - Every Titan function closure carries the lightuserdata sentinel `TITAN_BRAND`
     in `upvalue[3]`.
   - Every nominal or owned Titan userdata metatable has `TITAN_BRAND` mapped to an
     integer kind:
     - `TITAN_ARRAY` (1): mutable dense array
     - `TITAN_CONST_ARRAY` (2): const dense array
     - `TITAN_RECORD` (3): record
     - `TITAN_UNION` (4): union
     - `TITAN_INTERFACE` (5): interface wrapper
     - `TITAN_OWNED` (6): owned foreign pointer or array (`COwned`)

2. **Serialized type descriptors (`TITAN_MT_TYPE`)**:
   - Stored as a lightuserdata key on record, union, interface, and owned C
     metatables containing the compiler's serialized schema (`types.serialize(...)`).

3. **Member and static tables (`TITAN_MT_MEMBERMAP`, `TITAN_MT_STATICS`)**:
   - `TITAN_MT_MEMBERMAP`: maps field names to indices and method names to closures.
   - `TITAN_MT_STATICS`: maps constructor names (such as `Point.new` or variant
     constructors) and static function names to callable closures.

4. **Global registry (`TITAN_METATABLES_KEY`)**:
   - Maps each fully-qualified type name (`"module.TypeName"`) to its canonical
     metatable in Lua's registry.

## Dynamic type descriptor hydration

Rather than embedding a complex ad-hoc parser, `titan.reflect` hydrates the
serialized descriptor strings produced by `types.serialize` using an isolated
execution environment in `lua.load`:

- The hydration environment defines constructor functions matching the serializer's
  expression syntax (`Record`, `Union`, `Interface`, `Field`, `Variant`, `Method`,
  `StaticMethod`, `Function`, `Array`, `Map`, `Nominal`, `COwned`, etc.).
- When hydrating nominal descriptors with an active metatable context, methods and
  constructors are resolved directly from `TITAN_MT_MEMBERMAP` and `TITAN_MT_STATICS`,
  providing callable closures (`MethodType.callable`, `StaticFunctionType.callable`,
  `VariantType.callable`).
- Hydrated descriptors are cached by metatable (`mt_cache`) and by qualified name
  (`nominal_cache`) to avoid redundant parsing and allocation.

## Record dynamic field access and GC safety

A `RecordValue` provides 1-based dynamic getter and setter operations:

```titan
function RecordValue:get(i: integer): value
function RecordValue:set(i: integer, v: value)
```

- **Bounds checking**: Validates `1 <= i <= n_fields`, raising an error on out-of-bounds
  access.
- **Const validation**: Inspects the field descriptor's `is_const` flag. Attempting to
  call `:set` on a const field raises a runtime error.
- **GC write barrier**: Writes are performed directly into the userdata's uservalue slot
  `self.uv[uv_idx].uv = v`, followed immediately by `lmacro_luaC_barrierback` (`luaC_barrierback`)
  without any Lua stack traffic. This maintains the generational garbage collection invariants for all
  collectable payloads.


## Interface reflection

An `InterfaceValue` provides:
- `iv.wrapped`: the underlying concrete record or union instance.
- `iv.descriptor`: the `InterfaceType` descriptor.
- `iv:get(i)`: reads the captured const field snapshot at index `i`. For interface
  wrappers, `uv[0]` holds the module pointer `_mod`, `uv[1]` holds the concrete
  instance, and `uv[i + 1]` holds the `i`-th field snapshot.

## Function reflection

`inspect(fn)` classifies function values into:
- `TitanFunctionValue`: verified by checking closure upvalues for `TITAN_BRAND`. Exposes
  `native_entry` (`upvalue[2]`), `lua_entry` (`cl->f`), and the hydrated
  `FunctionType` descriptor (`upvalue[1]`).
- `LuaFunctionValue`: Lua bytecode closures (`LClosure`), introspected using
  `lua_getinfo(L, ">Su", ...)` into line numbers, parameter counts, and source origin.
- `LuaCFunctionValue`: foreign or native C functions (`CClosure` or lightweight C
  function pointer `ttislcf`), exposing the C function pointer address `entry`.


## Owned foreign C storage

Owned C objects allocated via `T.new()` or `T.new_array(n)` are represented as
Titan `Udata` instances with metatables branded `TITAN_OWNED`.
- Pointer values (`OwnedForeignPointerValue`) expose payload memory `getudatamem(u)`
  and byte size `u->len`.
- Array values (`OwnedForeignArrayValue`) additionally read the element count stored
  in userdata uservalue `uv[0]`.
