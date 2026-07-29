# C FFI declarations, conversions, and expressions

The [C FFI overview](ffi.md) explains `foreign import`, the supported C type
families, owned allocation, and calls. This chapter covers the parts of the C
interface that participate directly in Titan declarations and expressions:
named C tags, automatic C objects, fixed arrays, contextual pointer
conversions, supported object-like macro values and field projections, and
operators evaluated with C semantics.

These facilities remain unsafe. The checker preserves C type and lifetime
rules that it can establish statically, and it asks the configured C compiler
to validate target-specific conversions and expressions. It does not make a C
pointer safe, extend automatic storage, or define behavior that C leaves
undefined.

## Named `struct` and `union` tags

A named file-scope C tag is source-nameable through the foreign module even
when the header does not declare a typedef:

```c
/* geometry.h */
struct Point {
    int x;
    int y;
};

union Cell {
    int integer_value;
    double number;
};

typedef struct Point Row[2];
```

```lua
local geometry = foreign import "geometry.h"

local function x_of(point: geometry.Point): integer
    return point.x as integer
end

local function clear(cell: geometry.Cell)
    cell.integer_value = 0
end
```

`geometry.Point` above denotes the real C type spelled `struct Point`, and
`geometry.Cell` denotes `union Cell`. Titan does not invent C typedefs for
these names. Generated declarations, casts, and probes retain the exact
`struct` or `union` spelling required by the header.

Only named tags introduced at file scope are published this way. Anonymous
aggregates, enum tags, and tags whose scope is only a function prototype are
not source aliases. A forward declaration such as `struct Opaque;` does
publish `module.Opaque`, but an incomplete aggregate may be used only behind a
pointer. By-value parameters, returns, locals, casts, field access, `sizeof`,
and allocation require the complete definition to be visible at that source
point.

### Real typedefs take precedence

C has separate ordinary-identifier and tag namespaces. Titan presents both
through the foreign module while preserving that distinction:

```c
typedef long Item;
struct Item { int value; };
```

Here `header.Item` is the real `typedef long Item`, regardless of whether the
typedef appears before or after the tag declaration. The tag still describes
C declarations that explicitly use `struct Item`, but Titan does not replace a
real typedef with the convenient tag alias.

All `struct` and `union` tags share C's one tag namespace in a scope. A visible
`struct Item` and `union Item` therefore conflict; they are not two overloads.
Forward declarations imported from separate headers complete the same
canonical tag when their kinds agree.

The ordinary value namespace remains separate. A header may legally declare
both `struct stat` and a function named `stat`, and Titan supports both:

```lua
local c = foreign import "sys/stat.h"

local function inspect(path: string): integer
    local info: c.stat
    return c.stat(path, info)
end
```

An ordinary value wins when a dotted expression is ambiguous. Consequently,
type pseudo-members such as `c.stat.new()`, `c.stat.new_array(n)`,
`c.stat.sizeof`, or `c.stat.alignof` are unavailable when the ordinary member
`c.stat` collides with the type name; the checker reports that collision
specifically. Fields named `new`, `new_array`, or `alignof` on an actual
aggregate value are ordinary C fields and remain usable (`sizeof` itself is a
C keyword and cannot name a field).

### Titan keywords as C names

Member and qualified-type lookup after a foreign namespace or C receiver uses
a contextual raw C identifier. A legal C spelling such as `when`, `type`, or
`repeat` is therefore available as `c.when`, `c.type`, or `object.repeat`
when the imported declarations provide it. This does not unreserve the word
for an ordinary Titan variable, declaration, record field, union variant, or
member. Named C parameter labels use the analogous contextual rule before
`=` in a named call.

## Contextual object-pointer conversions

C libraries often expose related opaque structures as different pointer types
and require the caller to use a cast. Libuv handles are a familiar example:
converting `uv_tcp_t *` to `uv_handle_t *` is a documented C cast convention,
not inheritance or a subtype relationship in Titan.

Titan admits such conversions only in a context that already supplies the
destination C pointer type:

```lua
local function close_tcp(tcp: *uv.uv_tcp_t)
    uv.uv_close(tcp, nil)                 -- parameter supplies *uv_handle_t
end

local function as_handle(tcp: *uv.uv_tcp_t): *uv.uv_handle_t
    return tcp                            -- return type supplies the target
end

local function explicit(tcp: *uv.uv_tcp_t): *uv.uv_handle_t
    return tcp as *uv.uv_handle_t
end
```

The same rule is used for annotated locals, assignment, positional and named C
arguments, C function-pointer calls, returns, explicit casts, and typed C
variadic arguments. The configured C compiler validates the exact directional
cast using the fixed standard/Lua/Titan header prefix, ordered foreign-header
block, and target/toolchain inputs selected for generated compilation.
Independent declaration extraction does not include the fixed prefix or
cumulative earlier-import macro state; headers whose declarations depend on
either need the
[umbrella-header discipline described in the FFI limitations](ffi.md#current-limitations).
A compiler rejection is a Titan type error; a broken header or toolchain probe
is reported as a probe failure, not as an incompatible conversion.

Guardrails apply before the compiler probe:

* both sides must be C object pointers after array decay;
* object pointers never convert directly to function pointers, or conversely
  (the separate written function-pointer-to-`void *` erasure is not an unsafe
  object-pointer reinterpretation);
* reachable `const` or `volatile` qualification may be added but not discarded;
* qualifiers carried by typedefs and array element types remain effective;
* the conversion is directional and does not change the global
  `types.compatible` relation.

Fixed C arrays decay to their element pointer before this rule is considered.
An automatic or imported array is therefore passed as the array expression,
not as `&array`.

Source-written owned C storage participates in the same destination-directed
pointer adjustment:

```lua
local c = foreign import "geometry.h"

local function use_owned()
    local point: owned *c.Point = c.Point.new()
    local points: owned c.Point[] = c.Point.new_array(8)
    local mutable: *c.Point = point
    local immutable: const *c.Point = points
    c.read_point(point)
    c.read_point(points)
end
```

A scalar owner supplies a pointer to its one payload object; a counted owner
supplies a pointer to its first element. The owner remains the GC root while
the adjusted pointer is live for the C call. Qualification follows the same
inclusion rule as array decay and ordinary pointer conversion: mutable storage
may become `T *`, `const T *`, or a permitted `void *`, but qualification on
the owned payload may not be discarded. An optional owner must be unwrapped
before adjustment. Making the destination pointer optional does not combine
the two operations: `owned *T?` does not implicitly become `*T?`.

One separate written conversion erases stable native identities to C
`void *`. Every non-function C pointer keeps the ordinary C object-pointer
conversion, while a C function pointer uses Titan's toolchain portability
cast. A Titan Array or Map exposes its backing `Table *`; a record or Titan
union exposes its full-userdata `Udata *`; and a function exposes the
collectable GC object
carried by its boxed `TValue`. A noncollectable function-typed value makes
`is C-void-pointer` false and makes `as C-void-pointer` raise. Strings remain
byte pointers and owned C objects remain payload pointers; neither switches to
its enclosing GC object's identity. An arbitrary `value` likewise does not
gain an identity interpretation.

All of these pointers are borrowed. The compiler evaluates a GC source once
and roots it while the cast and later arguments of the same call are prepared,
but retaining or returning the pointer does not retain the source object.
Code that lets C keep such a pointer must keep the original Titan value
reachable. `Table *`, `Udata *`, and function GC-object addresses are internal
runtime representations, so ordinary FFI code must not dereference, mutate,
free, or reallocate them.

This identity conversion is the only Titan-union/C-aggregate relation. A
Titan union is nominal tagged userdata, not a C `union`; neither it nor a
Titan record can be structurally cast to a C `union` or `struct`.

An existing address coercion still handles a by-value C object passed to a
pointer parameter. A mutable local or parameter may supply a mutable out
pointer; other by-value object expressions can supply only a compatible
`const` pointer. When the pointed-to types need the unsafe conversion above,
Titan first takes the permitted address and then emits the validated C cast.

## Zero-initialized automatic C objects

A local declaration with a C aggregate type may omit its right-hand side:

```lua
local c = foreign import "geometry.h"

local function origin(): integer
    local point: c.Point
    return (point.x as integer) + (point.y as integer)
end
```

This initializer-less production is deliberately narrow: its source grammar is
exactly `local name: module.Type` or
`local name: module.Type[positive_literal]`. A Titan alias that happens to
resolve to a C type, a direct pointer spelling, an option marker, multiple
declarations, or an inferred type does not enter this production. Initialized
locals continue to use the ordinary, more general declaration grammar.

This is not an uninitialized Titan local. It emits a C automatic object with a
`{0}` initializer, so the complete object is zero-initialized according to C.
The no-right-hand-side form is accepted only for:

* a complete C `struct`;
* a complete C `union`;
* a fixed-size C array whose complete element type is eligible recursively.

It is rejected for C scalars, pointers, `void`, incomplete aggregates,
flexible-array-member structs, unsized or zero-length arrays, and aggregates
that transitively contain Lua-GC-bearing FFI storage such as `TValue` or
`Udata *`.

An initialized C local keeps the ordinary declaration syntax:

```lua
local point: c.Point = c.make_point()
```

## Fixed C arrays

A positive literal extent after a C element type declares an automatic fixed
array:

```lua
local ffi = foreign import "titan/ffi.h"
local geometry = foreign import "geometry.h"

local bytes: ffi.titan_ffi_unsigned_char[256]
local points: geometry.Point[8]
local matrix: geometry.Row[4] -- imported array typedefs may be nested
```

The extent is a positive compile-time integer literal. Indexing is zero-based,
because the generated expression is a C array access:

```lua
bytes[0] = 65 as ffi.titan_ffi_unsigned_char
bytes[255] = 0 as ffi.titan_ffi_unsigned_char
```

`#array` is the fixed element count. Direct indexing of a statically sized C
array is checked against that count; indexing through a decayed/raw C pointer
is unchecked. In a pointer context the array decays to a pointer to its first
element, retaining element qualification.

C arrays are not assignable values. Titan rejects whole-array inference,
copy-initialization, assignment, return, and capture. Element and field writes
remain available, and a pointer obtained by decay may be captured like any
other C pointer.

Automatic aggregates and arrays have ordinary C block lifetime. Titan performs
no escape analysis: returning, storing, or capturing a pointer to automatic
storage can leave a dangling pointer after the block or function returns. The
programmer owns that lifetime contract.

The `T.new()` and `T.new_array(count)` forms allocate GC-owned C storage. Their
result types can be written as `owned *T` and `owned T[]`, respectively. These
owners differ from automatic objects: they may be stored in local aliases,
record fields, options, local callables, Arrays, and Maps, and their storage
lives as long as the owner remains reachable. They still cannot appear in a
public module interface, because their C payload type belongs to the importing
module.

## A callback-options example

Automatic objects, named tags, function-pointer casts, and address coercion can
be combined without a private Titan runtime wrapper. Suppose a host library
provides:

```c
/* process_fixture.h */
typedef void (*process_exit_callback)(int status, void *data);

struct ProcessOptions {
    const char *file;
    process_exit_callback on_exit;
    void *data;
};

extern void host_report_exit(int status, void *data);
extern int host_spawn(const struct ProcessOptions *options);
```

Titan can construct the options in automatic storage and pass its address:

```lua
local host = foreign import "process_fixture.h"

local function spawn(file: string): integer
    local options: host.ProcessOptions
    options.file = file
    options.on_exit =
        host.host_report_exit as host.process_exit_callback
    options.data = nil
    return host.host_spawn(options) as integer
end
```

The callback is a host-provided C function and the call remains an ordinary C
ABI boundary. Titan does not adapt a Titan function or closure to a C callback
ABI; only a compatible C function or C function-pointer value can fill this
field.

## C operator mode

An operator uses C mode when at least one operand is a C scalar, C pointer, or
C array and the combination appears in the following table. Otherwise the
existing Titan operator rules are unchanged.

| Titan syntax | C-mode operands | Result |
| --- | --- | --- |
| `-x` | C integer or C float | promoted integer or original C float |
| `~x` | C integer | promoted C integer |
| `a + b` | arithmetic pair; complete object pointer/array plus integer | usual C arithmetic type or pointer |
| `a - b` | arithmetic pair; pointer/array minus integer; compatible complete object pointers | usual C type, pointer, or Titan `integer` for pointer difference |
| `a * b`, `a / b` | arithmetic pair | usual C arithmetic type |
| `a % b` | C integer pair | usual C arithmetic type |
| `<`, `<=`, `>`, `>=` | arithmetic pair or compatible object pointers | Titan `boolean` |
| `==`, `~=` | arithmetic pair; object/`void`-pointer pair; pointer and `nil`; matching function pointers | Titan `boolean` |
| `a & b`, `a \| b`, binary `a ~ b` | C integer pair | usual C arithmetic type |
| `a << b`, `a >> b` | C integer pair | promoted left C integer type |

Titan `~=` emits C `!=`, and binary Titan `~` emits C `^`. Arrays decay before
the operator is classified. Both operands are evaluated once in source order,
then the generated C operator is applied to the temporaries.

The following remain Titan operations and never acquire C meaning: `//` floor
division, `^` exponentiation, `and`, `or`, `not`, concatenation, and the
existing meanings of `#`. `COwned` is a Titan userdata wrapper rather than a C
operand; a context must first adjust it to its payload pointer.

Unsupported C combinations are errors rather than a fallback to Titan numeric
helpers. These include floating remainder, aggregate operators, arithmetic on
`void *`, function pointers, or incomplete-object pointers, relational
function-pointer comparison, and pointer multiplication, division, modulo,
bitwise operations, or shifts. A C bit-field expression must first be cast to
an ordinary C or Titan integer, because its declared width can affect C integer
promotion.

### Promotions and mixed Titan operands

C integer promotions and usual arithmetic conversions determine result types.
Arithmetic drops typedef identity and produces the target's resolved primitive
C type. Float rank follows C (`long double`, `double`, `float`), shifts use the
promoted left type, and pointer subtraction produces a Titan `integer`.

A Titan `integer` mixed with a C operand participates as the configured
`lua_Integer`; a Titan `float` participates as the configured `lua_Number`.
The compiler reads those types and all C integer widths, ranks, signedness, and
ranges from the active target toolchain. It does not assume the Lua process
running the compiler has the same data model.

This distinction matters. In `small_unsigned + titan_integer`, the small C
operand is promoted and then combined with `lua_Integer`; the Titan operand is
not first narrowed to the original small type. Pointer addition and subtraction
accept a Titan integer offset. Pointer equality accepts Titan `nil` as a
target-typed null pointer; other pointer/integer comparisons are rejected.

Compatible object pointers use a symmetric common pointer type. Equality
between otherwise unrelated object pointers is allowed through a qualified
`void *` common type. That unrelated-pointer fallback is not used for ordering,
subtraction, or pointer arithmetic. Function pointers support equality only
when their types match.

### C behavior remains C behavior

C-mode code emits the direct C operator. It deliberately does not use Titan's
wrapping arithmetic helper, floor-division correction, modulo correction,
normalized shifts, exponentiation, numeric comparison helpers, or
divide-by-zero guard. For example:

```lua
local q = (c_value(-7) / c_value(3))  -- C result: -2
local r = (c_value(-7) % c_value(3))  -- C result: -1
```

Unsigned conversion and wrap, signed overflow, division by zero, invalid
shifts, and implementation-defined right shift consequently have their C
meaning. Some of those cases are undefined behavior. Titan does not add safety
checks or define a portable result; use an explicit Titan conversion before
the operation when Titan semantics are required.

## C constants and macro-projected fields

Top-level enum constants and supported object-like macros are direct members of
the foreign module:

```lua
local uv = foreign import "uv.h"
local signal = foreign import "signal.h"

local function imported_constants(): integer
    local cancelled = uv.UV_ECANCELED
    local readable = uv.UV_READABLE
    return (cancelled as integer) + (readable as integer)
end

local function signal_handlers_differ(): boolean
    local ignored_handler = signal.SIG_IGN
    return ignored_handler ~= signal.SIG_DFL
end
```

Supported integer-constant expressions retain their target-correct C integer
type. In addition, when a macro's fully expanded replacement is an outer cast
to a supported C scalar type, Titan imports the value with that cast's target
type. The target may be an integer, floating, object-pointer, or
function-pointer type. Generated C still names the public macro (`SIG_IGN`
above), leaving the host compiler to expand it under the same headers and
flags; Titan does not paste the implementation-specific replacement into the
generated file.

The existing bounded expression importer also recognizes typed dereferenced
accessors, such as the common `errno` expansion `*accessor()`, when the imported
accessor declaration establishes the result type. This is not general support
for arbitrary call-containing object macros.

Some system headers expose a public field name as an object-like macro whose
replacement is only a dotted identifier path, for example:

```c
typedef struct RecordStorage {
    int member;
} RecordStorage;

typedef struct Record {
    RecordStorage implementation;
} Record;

#define public_member implementation.member
```

Titan resolves such a projection lazily against the receiver's C aggregate
type and the final macro environment produced by all foreign headers in the
module. This matches generated C, which includes those headers before every
declaration and body: a later definition or dependency redefinition also
affects an earlier closure initializer, while a later `#undef` removes the
projection. A live macro takes precedence over a physical field with the same
public name, matching preprocessing before C field lookup. Source continues to
use and generated C continues to emit the public spelling:

```lua
local c = foreign import "header.h"

local function set_public_member(): integer
    local item: c.Record
    item.public_member = 1
    return item.public_member as integer
end
```

The final replacement must be a pure identifier path. Indexing, calls,
operators, casts, and other arbitrary macro expressions do not become
projected fields. If an active object-like macro with such an unsupported
replacement has the same name as a physical field, Titan reports an error
instead of selecting that field: C preprocessing would rewrite the token before
field lookup.

The preprocessor expands macro arguments according to C rules: ordinary
parameter occurrences use a prescanned argument, while `#` stringification and
`##` token paste use its raw preprocessing tokens. Stringification preserves
token adjacency, collapses actual whitespace/comments to one space, and
escapes quotes and backslashes. This is why token-pasted families such as
libuv's `UV_E*` names import directly; they do not require a Titan-specific
enum exception.

Function-like macros remain unavailable as foreign members. Other object-like
forms beyond recognized existing integer/accessor expressions, fully expanded
outer casts to supported scalar types, and pure dotted field projections are
not generally supported. Declaration extraction still preprocesses each
imported header independently, so a macro whose meaning depends on state
established by another import remains subject to the
[umbrella-header discipline described in the FFI limitations](ffi.md#current-limitations).
Ordinary field-macro definitions, dependency rescans, and undefinitions are
replayed into a final module environment. Conditional macro behavior whose
result itself depends on an earlier import, and later changes to a scalar macro
whose type was inferred in an earlier import, still require one umbrella
header.

## Related chapters

* [The C FFI](ffi.md) covers imports, calls, fields, ownership, and the wider
  type boundary.
* [Statements](statements.md) covers ordinary initialized local declarations.
* [Expressions](expressions.md) describes Titan operator semantics and
  precedence outside C mode.
* [Types](types.md) describes Titan's normal coercion and compatibility rules.
