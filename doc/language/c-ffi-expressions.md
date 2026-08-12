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
a contextual raw C identifier. A legal C spelling such as `when`, `type`,
`repeat`, or `interface` is therefore available as `c.when`, `c.type`,
`object.repeat`, or `c.interface` when the imported declarations provide it.
This contextual rule continues to apply when a spelling is a current or future
Titan keyword; it does not make a reserved spelling available for an ordinary
Titan variable, declaration, record field, union variant, or member. Named C
parameter labels use the analogous contextual rule before `=` in a named call.

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
  symmetric gradual-consistency relation. It remains one explicit,
  destination-directed C conversion plan.

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
union, or Interface exposes its full-userdata `Udata *` (the Interface address
is the wrapper, not its concrete value); and a function exposes the
collectable GC object carried by its boxed `TValue`. A noncollectable
function-typed value makes
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
Titan record can be structurally cast to a C `union` or `struct`. An Interface
likewise cannot be constructed from or cast to a C aggregate.

An existing address coercion still handles a by-value C object passed to a
pointer parameter. A mutable local or parameter may supply a mutable out
pointer; other by-value object expressions can supply only a compatible
`const` pointer. When the pointed-to types need the unsafe conversion above,
Titan first takes the permitted address and then emits the validated C cast.

## Target-directed C allocation

Every local declaration has an initializer. This includes C structures,
unions, and fixed arrays: the former initializer-less C-local form no longer
exists. Use `.new()` or `.new_array(...)` to ask for zeroed storage explicitly.

The constructor's representation is selected at its direct local declaration
sink. The checker records one allocation plan there; moving the call to a
return, argument, later assignment, or nested expression retains the ordinary
GC-owned result.

For a complete non-GC-bearing C structure or union `T`, `.new()` selects:

| Declaration | Local representation |
| --- | --- |
| `local x = T.new()` | automatic `T` |
| `local x: T = T.new()` | automatic `T` |
| `local x: owned *T = T.new()` | GC-owned object |
| `local x: *T = T.new()` | pointer into a hidden rooted owner |
| any non-direct-local use | `owned *T` |

Automatic inference is deliberately limited to structures and unions; it does
not make scalar, pointer, enum, function, incomplete, or C-array-typedef
payloads into stack objects. An automatic aggregate must not transitively
contain GC-bearing FFI storage.

For `T.new_array(count)`, a positive source integer literal can select fixed
automatic storage:

```titan
local inferred = c.Point.new_array(4)       -- c.Point[4]
local exact: c.Point[4] = c.Point.new_array(4)
local view: c.Point[] = c.Point.new_array(4) -- borrowed pointer
local ptr: *c.Point = c.Point.new_array(4)   -- borrowed pointer
local owner: owned c.Point[] = c.Point.new_array(count)
```

An explicitly written fixed extent must be positive and equal the literal
allocation count. A fixed C-array typedef imported from C may be an element only when a
positive literal selects nested automatic backing; it cannot become an owned
payload. A dynamic or zero count cannot create a C fixed array. An
inferred dynamic/zero count remains `owned T[]`; an explicit borrowed pointer
or `T[]` gets hidden owned backing instead. An explicit `owned T[]` always
wins. `T[]` is an uncounted pointer view: `#view` is unavailable and indexing
has raw-pointer semantics.

The source spellings `c.T[N]` and `c.T[]` are available only as the written
target of an initialized direct allocation local. A fixed array is 0-based,
`#array` is its fixed extent, and direct indexing is checked against that
extent. It decays to an element pointer in pointer contexts. A whole C array is
not an assignable/returnable value.

Automatic storage has ordinary C block lifetime and no escape analysis. A
pointer returned, stored, or captured beyond that lifetime can dangle. A
hidden owned backing is rooted for the containing Titan function frame, but a
borrowed pointer returned from that frame still loses ownership. Write an
explicit owner when storage must escape.

A matching automatic aggregate can initialize `owned *T`, and a matching fixed
array can initialize `owned T[]`. Titan allocates one userdata, copies the
complete object representation, and publishes that owner. This is one direct
checker-planned copy, not subtyping or a conversion lifted through containers.

## Flexible-array-member allocation

If a complete C structure `T` ends in `E field[]`, allocate one extended object
with `T.new(count)`:

```titan
local packet = c.Packet.new(8)                 -- literal automatic extent
local owner: owned *c.Packet = c.Packet.new(n) -- dynamic owned extent
local pointer: *c.Packet = c.Packet.new(n)     -- hidden owner backing
```

`T.new()` has the wrong arity and `T.new_array(...)` is unavailable for a FAM
structure. Titan never invents a stride for an array of variably extended
objects.

A direct inferred/by-value local with a nonnegative integer literal gets
aligned automatic byte backing. An explicit owner/pointer, dynamic count, or
non-direct-local use gets one owner userdata. Both are zeroed through:

```text
max(sizeof(T), offsetof(T, field) + count * sizeof(E))
```

The compiler checks an automatic literal against the configured target's exact
`size_t` extent and rejects it if the addition or multiplication would overflow.
Owned allocation evaluates the count once, rejects a negative count, and checks
size overflow at run time. While the original owner or automatic local retains its count,
`field[i]` is bounds-checked and `#field` returns that logical count. Converting
the parent to raw `T *` erases the provenance; a FAM reached through that raw
pointer has neither length nor count-aware indexing.

Automatic objects and arrays are spilled and reloaded across catchable Titan
calls so mutation made before a caught error remains observable. FAM backing
uses the same protocol for its full dynamic extent.

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
    local options = host.ProcessOptions.new()
    options.file = file
    options.on_exit =
        host.host_report_exit as host.process_exit_callback
    options.data = nil
    return host.host_spawn(options) as integer
end
```

The callback in this example is host-provided and the call remains an ordinary
C ABI boundary. A compatible restricted Titan `foreign function` can also fill
this field; an ordinary Titan function or closure is never adapted implicitly.
See [Foreign functions](foreign-functions.md).

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
The subtraction itself has the target's exact `ptrdiff_t` type; the subsequent
conversion to `lua_Integer` is checked and raises if the result is not
representable rather than narrowing silently.

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

Ordinary C integer promotions and signed/unsigned usual-arithmetic
conversions keep those C semantics. When an operator instead requires an
integer-to-floating conversion whose range the active target profile cannot
prove sufficient, Titan checks the operand before performing the C cast. A
failure raises a normal type error rather than evaluating an out-of-range C
conversion. Exact C results otherwise remain raw C values until a later
Titan/Lua carrier boundary requests conversion.

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
* [Types](types.md) describes Titan's separated consistency, coercion,
  written-cast, callable-adjustment, and boundary rules.
