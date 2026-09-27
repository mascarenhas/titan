# Native storage in records and unions

Record fields and union parts can hold native C values without first converting
them to Lua values. They can also embed complete C structs, C unions, and fixed
C arrays. This is useful for an owner that keeps native state beside ordinary
Titan fields, or a small container that owns its own buffer.

Records and unions retain their ordinary nominal identity, visibility,
constructors, and garbage collection. A field's declaration position still
determines its positional constructor argument. A union part still has its
declared name and position. Storage choices do not expose private members or
change those source-level rules.

## Which values can be stored

Ordinary Titan fields and parts remain supported. Strings, functions, records,
unions, Interfaces, Arrays, Maps, `value`, and `owned` C objects retain their
normal shared identity and garbage-collected lifetime. Exact foreign `TValue`
and Lua-internal `Udata *` values also remain traced.

Titan scalars and foreign numeric values keep their native values. Raw C
object and function pointers keep their pointer values; storing one does not
keep the pointed-to object alive.

A fixed embedded C object must have a complete definition, a supported
alignment, and no contained GC-bearing storage. A C struct containing a
`TValue`, for example, cannot be embedded. A struct with a flexible array
member cannot be embedded by value, including indirectly through another
struct or C union. Use a pointer and a fresh extended allocation for it, as
described below.

Fixed C arrays come from imported declarations, such as a C `typedef int
Row[3]`. Titan still has no source-written `foreign int[3]` type syntax. A fixed
array initializer must have a compatible known extent; an arbitrary pointer
does not supply an array's length.

The existing [foreign-type export restrictions](ffi.md#c-types-in-titan) still
apply. A header-dependent C type cannot become part of a public compiled-module
interface. Keep such storage in a local field or local nominal declaration.
By-value C objects do not become eligible for `value`, ordinary Titan Arrays,
or Maps just because a record or union can store them.

## Copying a fixed object and borrowing its address

Construction copies a fixed C aggregate or array into the new record or union.
Later changes to the initializer's storage do not change that copy. Reading the
field, or binding the union part in a `case`, produces a borrowed pointer to the
stored object. A fixed array projects to its element pointer.
Replacing a mutable embedded field with a compatible fixed object copies the
replacement into that field; a const field cannot be replaced.

For example, place these declarations in `native_shapes.h`:

```c
typedef struct Point { int x; int y; } Point;
typedef int Row[3];
static Row starting_row = { 10, 20, 30 };
```

The following `shapes.titan` module can be compiled with `titanc shapes`:

```titan
foreign import "native_shapes.h"

local record Shape
    const point: foreign Point
    const row: foreign Row
end

function example(): integer
    local source = foreign Point.new()
    source.x = 12
    local shape = Shape.new(source, ffi.starting_row)
    source.x = 99

    local point = shape.point
    point.y = 20
    shape.row[0] = 10
    return shape.point.x + shape.point.y + shape.row[0] -- 42
end
```

Here `point` has type `foreign *Point`, and `shape.row` has type `foreign *int`.
Neither read allocates a wrapper or copies the stored object. The same rule
applies to union case binders.

Field constness is shallow: `shape.point = another_point` is forbidden, while
`shape.point.x = 1` mutates the object reached through its borrowed pointer and
is allowed. A declared C `const` qualification remains effective; Titan does
not discard it when projecting the pointer. A const *local containing a C
object by value* follows the separate local-storage rules in
[Const values](const-values.md#c-const-is-separate).

Keep the containing record or union reachable for as long as a projected
pointer is used. Saving only the raw pointer does not retain its owner. This
also applies when a pointer escapes a case arm, is returned from a function,
or is saved by C. Ordinary field access keeps the receiver alive for the
access; it does not turn an escaped pointer into an owning reference.

## A fresh buffer can share its owner's allocation

An unsized field such as `foreign int[]` is a borrowed element-pointer view.
When a direct generated constructor receives a fresh allocation for a const
field, Titan can place the new zeroed buffer in the same allocation as the
record. Union parts support the same construction because a part cannot later
be replaced.

This complete module provides a checked, 1-based interface over that buffer:

```titan
record NativeIntArray
    const length: integer
    local const array: foreign int[]
end

function NativeIntArray.make(len: integer): NativeIntArray
    return NativeIntArray.new(len, foreign int.new_array(len))
end

function NativeIntArray:get(i: integer): integer
    if i < 1 or i > self.length then raise "out of bounds" end
    return self.array[i - 1]
end

function NativeIntArray:set(i: integer, n: integer)
    if i < 1 or i > self.length then raise "out of bounds" end
    self.array[i - 1] = n
end
```

The raw `array` pointer itself has no `#` operation or automatic bounds checks.
The `length` field and methods provide those contracts. A zero count is valid:
its pointer is non-NULL and distinct from another fresh empty buffer in that
owner, but no element may be read or written. Negative counts and allocation
size overflow raise before an object is returned.

The fresh call must be an argument of a direct generated record or variant
constructor. Positional and named calls preserve source argument order and
evaluate each count once. Several fresh fields may share one owner; a buffer
need not be the final declared field. A direct fresh `.new()` can likewise
initialize an eligible fixed aggregate field in its final storage.

An existing pointer remains a borrowed pointer. An existing `owned` object is
not moved, copied into its caller, or given a different identity. Mutable
pointer fields, indirect constructor calls, Lua calls, and reflected calls do
not acquire fresh-allocation ownership. If a pointer refers to separate
storage, retain that storage's owner independently.

Initialize native objects that retain their own address only after constructing
the final owner. For example, construct a record with a fresh zeroed native
handle, then pass the projected field pointer to the C initialization function.
Copying an already initialized handle can leave internal pointers referring to
the original storage.

## Flexible array members

A C struct ending in a flexible array member uses a pointer field or part and
a fresh `foreign Packet.new(count)` argument. Titan places the complete
extended object in the owner's trailing storage; it never embeds only the
struct's fixed prefix.

For a header declaring `struct Packet { int kind; int values[]; };`, a local
owner can use:

```titan
foreign import "packet.h"

local record PacketOwner
    local const packet: foreign *Packet
end

local function new_packet(count: integer): PacketOwner
    local owner = PacketOwner.new(foreign Packet.new(count))
    owner.packet.kind = 1
    return owner
end
```

The pointer remains an uncounted C pointer. It does not preserve the allocation
count as a `#` or checked-indexing contract; retain a separate length and use
an explicit element-pointer view when accessing the flexible member. Its
lifetime is the enclosing owner's lifetime. The normal FAM allocation rules,
including alignment and size checks, are described in
[Flexible-array-member allocation](c-ffi-expressions.md#flexible-array-member-allocation).

## Exact native values and Lua conversion

A foreign integer or float stored in a record or union keeps its declared C
value. Native numeric Options also preserve the exact present value and a
separate absence state through typed locals, arguments, returns, and nominal
storage. Wrapping a large C integer in an Option does not force it into a Lua
integer.

For example, this module preserves the target's `unsigned long long` maximum:

```titan
foreign import "limits.h"

record Counter
    count: (foreign unsigned long long)?
end

function maximum(): Counter
    return Counter.new(ffi.ULLONG_MAX)
end

function is_maximum(counter: Counter): boolean
    if not counter.count then return false end
    return (counter.count as foreign unsigned long long) == ffi.ULLONG_MAX
end
```

Conversion is checked when a value actually crosses into a narrower numeric
type or a boxed boundary such as Lua, `value`, an Array or Map element, an
Interface field snapshot, or reflection. On a target where `ULLONG_MAX` does
not fit Lua's integer carrier, `maximum()` still succeeds, but reading its
`count` field from Lua raises. A failed read leaves the native field unchanged.
Writes convert before changing the destination, so a failed Lua/reflected
write also leaves the old value intact.

Reflection exposes a fixed aggregate/array projection as a borrowed raw address,
not a copied `owned` object or a Titan Array. It does not make arbitrary
lightuserdata safe to assign to typed pointer fields. JSON continues to use
public reflection and constructor rules; private fields stay absent, and a
native number may fail conversion when JSON requests its Lua carrier.

Rebuild compiled providers and consumers together when changing compiler ABI.
Separate compilation preserves public access without making a producer's
private C headers part of the consumer's interface.
Within a matching ABI, [shared-provider replacement](binary-compatibility.md)
allows private record storage to change while public fields retain their
ordered names, erased types, and constness. Imported record literals depend on
public `new`, so adding the first private field rejects old construction
consumers while compatible accessor-only consumers can continue to load.
