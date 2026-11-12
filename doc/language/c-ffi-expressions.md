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
foreign import "geometry.h"

local function x_of(point: foreign Point): integer
    return point.x as integer
end

local function clear(cell: foreign Cell)
    cell.integer_value = 0
end
```

`foreign Point` above denotes the real C type spelled `struct Point`, and
`foreign Cell` denotes `union Cell`. Titan does not invent C typedefs for
these names. Generated declarations, casts, and probes retain the exact
`struct` or `union` spelling required by the header.

Only named tags introduced at file scope are published this way. Anonymous
aggregates, enum tags, and tags whose scope is only a function prototype are
not source aliases. A forward declaration such as `struct Opaque;` does
publish `foreign Opaque`, but an incomplete aggregate may be used only behind a
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

Here `foreign Item` is the real `typedef long Item`, regardless of whether the
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
foreign import "sys/stat.h"

local function inspect(path: string, info: foreign *stat): integer
    return ffi.stat(path, info)
end
```

The value and type syntaxes are separate. `ffi.stat(path, info)` calls the C
function, while `foreign stat.new()` allocates its tag type and
`foreign stat.sizeof` queries its layout. A same-named value does not disable
these operations. Fields named `new`, `new_array`, or `alignof` on actual C
aggregate values remain ordinary fields (`sizeof` itself is a C keyword).

### Titan keywords as C names

Foreign type names and selectors after a C receiver accept raw identifiers. A legal C spelling such as `when`, `type`,
`repeat`, or `interface` is therefore available as `ffi.when`, `ffi.type`,
`object.repeat`, or `ffi.interface` when the imported declarations provide it.
The grammar also admits reserved words at its `AnyName` declaration/member
boundaries; ordinary locals and parameters still require nonreserved names. Named C
parameter labels use the analogous contextual rule before `=` in a named call.

## Compiled probe cache

Titan uses small C compilations to check foreign header baselines, enum
carriers, conversions, operators, and layout predicates. It remembers results
by SHA-256 of the complete C source before preprocessing. Include directives
count as text; authored header contents and compiler options do not affect the
key. A generated module-header query includes its stable logical header name
and a source-visible digest of the generated header bundle, so changes to the
module's own include plan change the query source.

The format-2 cache lives at `<prefix>/var/cache/titan-probes/2`. A nonempty
`TITAN_PREFIX` selects the prefix; otherwise Titan uses its installed prefix.
It stores both completed compiler acceptance/rejection and typed enum-selection
answers. One enum query compares all eligible integer carriers in one
compilation and reads the chosen stable carrier ID from the object file;
target code is never executed. Valid no-match and multiple-match answers are
also deterministic results. Enumerator value-range checking remains separate.

Malformed records and cache I/O failures are misses. A missing or malformed
enum object result, unavailable/interrupted compiler, or temporary-file/read/
cleanup failure remains retryable. If an authored header or compiler
configuration changes and results appear stale, clear that directory or set
`TITAN_PROBE_CACHE_DISABLE=1` to bypass persistent reuse. This applies to cached
rejections as well as acceptance. Titan still compiles final generated C
normally.

## Contextual object-pointer conversions

C libraries often expose related opaque structures as different pointer types
and require the caller to use a cast. For example, a C library may document
converting `Widget *` to `Object *`. That is a C cast convention, not inheritance
or a subtype relationship in Titan.

Titan admits such conversions only in a context that already supplies the
destination C pointer type:

```lua
local function close_widget(widget: foreign *Widget)
    ffi.destroy_object(widget)            -- parameter supplies *Object
end

local function as_object(widget: foreign *Widget): foreign *Object
    return widget                          -- return type supplies the target
end

local function explicit(widget: foreign *Widget): foreign *Object
    return widget as foreign *Object
end
```

The same rule is used for annotated locals, assignment, positional and named C
arguments, C function-pointer calls, returns, explicit casts, and typed C
variadic arguments. The configured C compiler validates the exact directional
cast using the fixed standard/Lua/Titan header prefix, ordered foreign-header
block, and target/toolchain inputs selected for generated compilation.
The module's `.ffi.h` supplies the same ordered authored/source-import header
chain used to build its `ffi` namespace. Direct source imports inherit that C
environment; probes do not rebuild it from individual types' origin headers.
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
foreign import "geometry.h"

local function use_owned()
    local point: owned *Point = foreign Point.new()
    local points: owned Point[] = foreign Point.new_array(8)
    local mutable: foreign *Point = point
    local immutable: foreign const *Point = points
    ffi.read_point(point)
    ffi.read_point(points)
end
```

A scalar owner supplies a pointer to its one payload object; a counted owner
supplies a pointer to its first element. The owner remains the GC root while
the adjusted pointer is live for the C call. Qualification follows the same
inclusion rule as array decay and ordinary pointer conversion: mutable storage
may become `T *`, `const T *`, or a permitted `void *`, but qualification on
the owned payload may not be discarded. An optional owner must be unwrapped
before adjustment. Making the destination pointer optional does not combine
the two operations: `(owned *T)?` does not implicitly become `foreign *T?`.

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

For a mutable object-pointer local or parameter, an exact pointer-to-pointer
target takes the address of the pointer variable itself. A `foreign const *char` local
can therefore receive a `const char **` output without discarding `const`.
This exact storage conversion does not change ordinary pointer-to-`void *`
value conversion. Const bindings, captured locals, and temporary expressions
cannot supply mutable pointer storage.
A written pointer `as` continues to cast the pointer's value, even when its
target is a pointer-to-pointer type; it does not implicitly take an address.

## Target-directed C allocation

An ordinary mutable local may omit its initializer only with an explicit type
whose representation admits nil. A C object or function pointer is in that
domain, so `local p: foreign *Point` starts as `NULL`. C structures, unions, fixed
arrays, numeric scalars, and enums do not admit nil and still require an
initializer. Use `.new()` or `.new_array(...)` to ask for zeroed aggregate
storage explicitly.

A const local always has an initializer. Constness on direct inline C
structure, union, or fixed-array storage is shallow but effective: the binding
cannot be replaced, its inline fields/elements cannot be mutated, and it cannot
take a mutable address or mutable automatic-decay path. Reaching separately
owned storage through a pointer ends that inline walk, so the pointee keeps the
mutability promised by the pointer type. This Titan binding rule is separate
from the C pointee qualifier in `foreign const *T`.

A direct local declaration selects the allocation representation described
below. Direct generated record and variant constructors also support final
embedded objects and fresh trailing buffers; see [Native storage in records and
unions](nominal-storage.md). Other return, argument, later-assignment, and
nested-expression uses retain the ordinary GC-owned result. A
[foreign function body](foreign-functions.md#zeroed-locals) accepts only the
automatic forms.

For a complete non-GC-bearing C structure or union `T`, `.new()` selects:

| Declaration | Local representation |
| --- | --- |
| `local x = foreign T.new()` | automatic `T` |
| `local x: foreign T = foreign T.new()` | automatic `T` |
| `local x: owned *T = foreign T.new()` | GC-owned object |
| `local x: foreign *T = foreign T.new()` | pointer into a hidden rooted owner |
| other uses outside a direct nominal constructor | `owned *T` |

Automatic inference is deliberately limited to structures and unions; it does
not make scalar, pointer, enum, function, incomplete, or C-array-typedef
payloads into stack objects. An automatic aggregate must not transitively
contain GC-bearing FFI storage.

For `foreign T.new_array(count)`, a positive integer literal or eligible macro can select fixed
automatic storage:

```titan
local inferred = foreign Point.new_array(4)       -- inferred fixed Point array
local view: foreign Point[] = foreign Point.new_array(4) -- borrowed pointer
local ptr: foreign *Point = foreign Point.new_array(4)   -- borrowed pointer
local owner: owned Point[] = foreign Point.new_array(count)
```

A positive constant count selects the fixed extent. Eligible object-like
integer macros use their exact target-profile value; named Titan constants and
arbitrary expressions are not folded for this selection. There is no allocation
size threshold. A fixed C-array typedef imported from C may be an element only
when a positive constant selects nested automatic backing; it cannot become an
owned payload. A dynamic or zero count cannot create a C fixed array.
An inferred dynamic/zero count remains `owned T[]`; an explicit borrowed pointer
or `foreign T[]` gets hidden owned backing instead. An explicit `owned T[]`
always wins. `foreign T[]` is an uncounted pointer view: `#view` is unavailable
and indexing has raw-pointer semantics.

Written `T[N]` annotations are removed. Inferred fixed arrays remain 0-based,
`#array` is the fixed extent, and direct indexing is checked against that
extent. They decay to element pointers in pointer contexts; a whole C array is
not an assignable or returnable value.

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
with `foreign T.new(count)`:

```titan
local packet = foreign Packet.new(8)                 -- literal automatic extent
local owner: owned *Packet = foreign Packet.new(n) -- dynamic owned extent
local pointer: foreign *Packet = foreign Packet.new(n)     -- hidden owner backing
```

`foreign T.new()` has the wrong arity and `foreign T.new_array(...)` is unavailable for a FAM
structure. Titan never invents a stride for an array of variably extended
objects.

A direct inferred/by-value local with a nonnegative integer literal gets
aligned automatic byte backing. An explicit owner/pointer, dynamic count, or
ordinary non-local use gets one owner userdata. A direct nominal constructor
can place a fresh FAM object in its own allocation. Every form zeroes the full
extent:

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

## C storage after a caught error

After a caught error, `catch` blocks, deferred statements, and code after a
handled `catch` see automatic C storage as follows.

**Locals and parameters whose mutable C address is exposed** keep one storage
location. What a C or ordinary Titan callee writes before raising is what
recovery sees: scalar values, pointers, structs, unions, fixed and nested
arrays, and the full automatic FAM extent. Direct array decay and inline
array-field decay count too. A `defer` guard can therefore observe an acquired
resource, or see that
[`transfer.decode_message`](standard-library-transfer.md#raw-packet-encoding-decoding-copying-and-disposal)
cleared its packet slot, without restoring an obsolete owner.

A caught error is not a transaction that undoes native writes: recovery never
restores the bytes such storage held before the raising call. Automatic C
storage whose mutable address is never exposed shows the value of its last
completed write.

Exact Lua-internal `TValue` and `Udata *` out-parameters follow the retained-write
rule as well. The compiler publishes their current values into existing GC
root slots before recovery can run close methods or collect, and clearing a
slot drops its old root. This does not remove the foreign writer's obligation
to keep fresh GC objects rooted through the handoff.

A borrowed pointer view (`foreign *T` or `foreign T[]`) preserves only the
pointer value; the backing bytes are not saved or restored. Retained raw
aliases that Titan does not track, asynchronous C writes, pointer lifetimes
and callback ownership remain the foreign code's responsibility.

This guarantee uses Titan's supported GCC and Clang toolchains, including
Clang on Windows (MSYS2), rather than strict ISO C. Generated C makes the
recovery home `volatile` and emits a declaration escape barrier; volatility
alone does not preserve an inlined indirect store. The callee still uses an
unqualified pointer, which ISO C 6.7.3p6 leaves undefined. The
[implementation chapter](../implementation/error-handling.md#setjmp-sensitive-localparameter-spills)
states the optimizer and link-time-optimization assumptions.

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
foreign import "process_fixture.h"

local function spawn(file: string): integer
    local options = foreign ProcessOptions.new()
    options.file = file
    options.on_exit =
        ffi.host_report_exit as foreign process_exit_callback
    options.data = nil
    return ffi.host_spawn(options) as integer
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

In a [foreign function body](foreign-functions.md#body-subset) the results are
the C99 ones, not the Titan-facing ones of the table: a pointer difference is
the target's `ptrdiff_t`, and the relational and equality operators give an
`int`, 0 or 1.

The following remain Titan operations and never acquire C meaning: `//` floor
division, `^` exponentiation, `and`, `or`, `not`, concatenation, and the
existing meanings of `#`. A foreign function body has only C operators, so
`//` and `^` are errors there, and the others are syntax errors. `COwned` is a
Titan userdata wrapper rather than a C operand; a context must first adjust it
to its payload pointer.

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
The subtraction itself has the target's exact `ptrdiff_t` type, which is the
type a foreign function body sees; in an ordinary function the subsequent
conversion to `lua_Integer` is checked and raises if the result is not
representable rather than narrowing silently.

For `+`, `-`, `*`, `/`, `%`, `&`, `|`, binary `~`, `<<`, and `>>`, a numeric
literal next to a C arithmetic operand has its unsuffixed C99 type:

* A decimal integer numeral uses the first of `int`, `long`, and `long long`
  whose range contains its value.
* A hexadecimal integer numeral uses the first of `int`, `unsigned int`,
  `long`, `unsigned long`, `long long`, and `unsigned long long` whose range
  contains its value.
* A floating numeral has type `double`.

An integer numeral that fits none of its C99 candidates is rejected. The
classification uses the integer spelling even when the same numeral would be
a Titan `float` outside C mode, as with decimal `9223372036854775808` on a
target whose `long long` has 64 bits.

Parentheses and unary `-` or `~` do not hide a literal operand. Unary operators
apply after the numeral is classified: `-1` negates C `int` `1`, and
`~0xFFFFFFFF` complements the hexadecimal constant in its classified type.
Titan's leading-zero decimal numerals remain decimal, not C octal constants.
The rule includes C typedefs, enum values, and `_Bool` operands. Thus an `int`
field can be updated with `response.fills = response.fills + 1`, a `size_t`
field with `response.length = response.length + 1`, and `c_float * 2` has type
`float`. In contrast, `c_float * 0.5` has type `double`; storing it into a C
`float` requires an explicit cast.

A non-literal Titan `integer` mixed with a C operand participates as the
configured `lua_Integer`; a non-literal Titan `float` participates as the
configured `lua_Number`. Comparisons and pointer offsets use that rule even
for literal operands. In particular, `c_unsigned < -1` compares in
`lua_Integer` rather than converting `-1` to `unsigned int`.
The compiler reads numeric widths, ranks, signedness, and ranges from the active
target toolchain, not from the Lua process running the compiler.

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

Literal arithmetic can therefore happen in a narrower type than Titan
`integer`: `c_int + 1` at `INT_MAX` and `c_int * 1000000` outside C `int`'s
range have signed-overflow undefined behavior. Similarly, `1 << c_n` uses C
`int` for its left operand and must obey that type's shift rules. A later wider
destination does not widen the computation, and storing a C `int` result into
an explicitly wider C integer type requires a cast.

Choose Titan arithmetic before the operation when wrapping arithmetic and a
range-checked store are wanted:

```text
response.fills = (response.fills as integer) + 1
```

To compute in a wider C type instead, cast an operand before the operator, for
example `(1 as foreign unsigned long long) << c_n`. C's overflow and shift
rules still apply to that wider type.

## C constants and macro-projected fields

Top-level enum constants and supported object-like macros are direct members of
the foreign module:

```lua
foreign import "errno.h"
foreign import "signal.h"

local function imported_constants(): integer
    local missing = ffi.ENOENT
    local denied = ffi.EACCES
    return (missing as integer) + (denied as integer)
end

local function signal_handlers_differ(): boolean
    local ignored_handler = ffi.SIG_IGN
    return ignored_handler ~= ffi.SIG_DFL
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

Floating literals in object-like macros retain their C type: an `f`/`F`
suffix selects `float`, an `l`/`L` suffix selects `long double`, and no suffix
selects `double`. Decimal and hexadecimal floating literals, signed exponents,
unary signs, and mixed arithmetic expressions are supported. Arithmetic and
conditional expressions select the highest floating rank among their numeric
operands; comparisons produce C `int`.

Ordinary `<math.h>` constants such as `INFINITY`, `NAN`, and `HUGE_VAL` also work
when the header expands them to GCC/Clang's `__builtin_inf*`,
`__builtin_huge_val*`, `__builtin_nan*`, or `__builtin_nans*` constant families.
The compiler recognizes only those builtins with their required argument
shape. This does not expose arbitrary function-like macros. Generated C names
the public object-like macro, so the native compiler evaluates finite values,
infinity, and NaN with the active target's floating semantics.

```titan
foreign import "math.h"

function infinity(): float
    return ffi.INFINITY
end
```

The existing bounded expression importer also recognizes typed dereferenced
accessors, such as the common `errno` expansion `*accessor()`, when the imported
accessor declaration establishes the result type. This is not general support
for arbitrary call-containing object macros.

An object-like macro whose fully expanded replacement is a single identifier,
with or without parentheses, has the type of the declaration it names. This
covers headers that define a standard stream as a macro naming its own
declaration, as in `extern FILE *const stdout;` followed by `#define stdout
(stdout)`, and headers that alias one declared name to another. The member
keeps the complete declaration: pointer qualifiers, array bounds, and callback
signatures. A replacement identifier with no visible declaration gives the
macro no type, rather than a guessed `int`:

```titan
foreign import "stdio.h"

local function write_line(line: string)
    local text = line .. "\n"
    ffi.fwrite(text, 1, #text, ffi.stdout)
end
```

Standard-stream replacements depend on the host header. Windows UCRT definitions
such as `#define stdout (__acrt_iob_func(1))`, and indexed-call forms such as
`#define stdout (&__iob_func()[1])`, are not imported macro values. Using
`ffi.stdout` then reports `member 'stdout' not found inside module 'ffi'`.
The declared accessor is still callable directly: on UCRT,
`ffi.__acrt_iob_func(1)` supplies the stdout pointer and
`ffi.__acrt_iob_func(2)` supplies stderr.

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
foreign import "header.h"

local function set_public_member(): integer
    local item: foreign Record
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
outer casts to supported scalar types, single declared identifiers, and pure
dotted field projections are not generally supported. All imported headers
are preprocessed in one
ordered module environment. Conditional declarations and supported scalar
macros therefore observe earlier headers, and later definitions or undefinitions
determine the final `ffi` members and projected-field behavior.

## Related chapters

* [The C FFI](ffi.md) covers imports, calls, fields, ownership, and the wider
  type boundary.
* [Statements](statements.md) covers ordinary initialized local declarations.
* [Expressions](expressions.md) describes Titan operator semantics and
  precedence outside C mode.
* [Types](types.md) describes Titan's separated consistency, coercion,
  written-cast, callable-adjustment, and boundary rules.
