# Foreign functions

Titan can define a function with a plain C ABI directly in Titan source. This is
useful for callbacks and other small native entry points that would otherwise
need a hand-written C trampoline.

```titan
foreign import "callback_api.h"

foreign function compare(left: *Item,
                         right: *Item): int
  if left.key < right.key then return -1 as int end
  if left.key > right.key then return 1 as int end
  return 0 as int
end

local function sort(items: foreign *Item, count: foreign size_t)
  ffi.sort_items(items, count, compare)
end
```

A foreign function is C code written with a restricted Titan surface. It is not
an ordinary Titan function with an automatically generated callback adapter.
The [C FFI chapter](ffi.md) remains the reference for imported declarations,
C types, calls, ownership, and allocation.

Portable C primitives such as `int`, `unsigned long`, `float`, and
`double` belong to the foreign type category and need no header import. Public
Titan signatures and public foreign declarations may expose exportable C type
graphs. Header-dependent types require the original compatible declarations in
the consumer's C environment; a regular import does not inherit C headers.

## Declaration syntax

A foreign function is a top-level declaration:

```text
[local] foreign function name(p1: C1, p2: C2): CResult
  body
end
```

Omit the result annotation for a C `void` function:

```titan
foreign function notify(item: *Item)
  ffi.mark_notified(item)
end
```

An ordinary foreign declaration is public. `local foreign function` keeps the
entry private to its source module and direct explicit source importers. There
is no foreign method, foreign record function, or nested foreign declaration.

Every parameter and the optional result must be a direct C FFI type. A complete
C struct or union can be passed or returned by value. Pointers to incomplete
objects are valid, but an incomplete object by value is not. Titan types,
including `integer`, `string`, `boolean`, and `value`, are not foreign-signature
types. `owned` views, direct array/function values, multiple results, flexible
results, and variadic parameters are also unavailable. Use a pointer in the
signature when C expects an array or callback.

The signature and the body write C types directly, without the `foreign`
prefix that marks a C type elsewhere in Titan: `item: *Item` in the signature,
`local count: size_t = 0` and `pointer as *Item` in the body.

A direct foreign call follows C arity rather than Titan call adjustment:
missing and surplus arguments are errors. Named-call syntax is available only
when the declaration has one complete fixed parameter-name list.

## Foreign function-pointer types

The source-written type

```text
foreign function (P1, P2): R
```

denotes a pointer to a C function taking `P1, P2` and returning `R`. Use `void`
for a C `void` result:

```titan
foreign type Compare = function (*Item, *Item): int
foreign type Notify = function (*Item): void
```

The type is already a pointer. Consequently, `foreign *(function(...): ...)` means a
pointer to a function pointer, not another spelling of the callback type.

A foreign declaration is a C function designator. It can be called directly or
used where an exactly compatible foreign function-pointer type is expected:

```titan
local callback: foreign Compare = compare
ffi.install_compare(compare)
```

It is not a Titan function value. It cannot inhabit `function(P...): R`, cross through
Lua, be boxed in `value`, or receive Titan callable adjustment. Conversely, an
ordinary Titan function or closure is not automatically adapted to a C callback
ABI. Write a foreign function that implements the required C boundary.

## Public exports and source visibility

The defining module can call or take the address of its foreign functions by
name. Regular imports expose public foreign functions through the module alias,
including inside other foreign functions:

```titan
local bridge = import "native.bridge"

foreign function forward(input: int): int
  return bridge.transform(input)
end
```

The exported signature must be an exportable C type graph. Compiled `.so` and
`.a` interfaces carry the exact C signature and parameter names. Module
initialization finds a shared provider through normal Titan runtime resolution:
an initialized canonical module, a matching native preload, or the runtime
search path. It checks compatibility before obtaining the raw address. A
statically included provider supplies its exact linked entry instead. Moving a
shared provider and selecting its new location at runtime requires no relink.

The imported address is stable for that physical consumer image. Calls and
callback conversions use the same actual C function pointer, without an
implicit Lua state or module argument. Independent Lua states may initialize
the image concurrently when they select the same address. A later state that
selects a different address fails initialization before the consumer can be
used; it cannot redirect callbacks already handed to C. A published binding
also remains stable if a later part of initialization fails. Ordinary Titan
function bindings retain their separate per-state behavior.

Public entries have one outlined definition. They are not Titan closures and
Lua cannot access them through `require`. Imported raw dependencies must be
initialized before a foreign entry using them is called; normal Titan imports
perform that initialization before exposing the entry.

A `local foreign function` is available to another module only through a
written explicit source-import alias:

```titan
local bridge = import "internal.bridge.titan"

local function install()
  ffi.install_callback(bridge.callback)
end
```

This local permission is direct and source-only. Source resolution without the
`.titan` marker does not grant it, and it does not propagate through an
intermediate module. A consumer of a `.so` or `.a` sees only the producer's
public interface; compiled metadata contains no local foreign function.
Physical co-residence in one provider and static linking do not change that
rule.

The source dependency's generated `.ffi.h` joins the consumer's C environment,
and its `.titan.h` supplies foreign-function declarations. C header inheritance
is transitive, but private Titan names remain available only through the direct
explicit source-import alias. See
[Visibility through explicit source imports](source-import-visibility.md).

## Body subset

A foreign body can use:

* its parameters and initialized C-typed locals;
* foreign functions in the current module;
* public foreign functions reached through a regular import, and local foreign
  functions reached through an explicit source import;
* imported C namespaces and their functions, values, fields, types,
  `sizeof`, and `alignof`;
* C calls, field and pointer/array indexing, C casts and C-mode operators;
* assignment and call statements;
* `do`, `if`/`elseif`/`else`, `while`, `repeat`, numeric `for`, `break`, and
  `return`.

It cannot see ordinary Titan module variables, functions, records, unions, or
methods, including ordinary members of an imported Titan module. Ordinary
functions receive built-in `L` and `M` locals; foreign functions do not. A
foreign body can call the Lua C API only when an explicit C parameter or other
C declaration supplies a `lua_State *`.

The body has a [grammar of its own](grammar.md#foreign-function-bodies), which
admits exactly this subset. A local annotation or a cast names a C type, and
only a C type: `local wide: long long = 5`, `raw as *Item`. Writing `foreign`
there is a syntax error that says to delete it, and a Titan type name such as
`integer` is looked up as a C type name, as in the signature. The allocation
and layout forms keep their prefix, because in an expression it is what
starts a type: `foreign T.new()`, `foreign T.new_array(N)`, `foreign T.sizeof`,
`foreign T.alignof`.

The following Titan constructs are syntax errors in a foreign body, each
with a message of its own at the place where the construct starts:

* `raise`, `catch`, `defer`, `case`, and generic `for ... in`;
* lambdas, `{...}` constructors, `:` method selection, and generic type
  arguments;
* `...`, spreads and ranges, `is`, the counted `as T(n)` cast, concatenation,
  and Titan `and`/`or`/`not`;
* `?` on a declaration or a type, `owned` types, Array and Map types, and more
  than one return value.

Two more are rejected by the checker:

* an allocation that needs a Lua owner: an allocation can only be the
  [zeroed storage of a local](#zeroed-locals);
* the length operator `#`.

A mutable local may omit its initializer only when its explicit type admits
nil, such as a C object or function pointer; the compiler supplies `NULL`.
Direct C aggregates and scalars still need an initializer (`foreign T.new()`
is the zeroing initializer of an aggregate), and every const local needs an
initializer. A non-void foreign function must return one C value on every
path; a void function may fall through or use bare `return`.

### Zeroed locals

A foreign body has no Lua state to allocate from and no frame that could root
an owner. The only C allocation it accepts is therefore the automatic storage
of a local that the allocation initializes directly. The forms and their
eligibility rules are those of an ordinary function
([target-directed C allocation](c-ffi-expressions.md#target-directed-c-allocation)):

| Declaration | Local |
| --- | --- |
| `local x = foreign T.new()`, or annotated `T`; `T` a complete struct or union | a zeroed `T` |
| `local a = foreign T.new_array(N)` | a zeroed `T[N]` |
| `local p: *T = foreign T.new_array(N)`, or annotated `T[]` | a pointer to a zeroed `T[N]` |
| `local f = foreign F.new(N)`; `F` ends in a flexible array member | a zeroed `F` with room for `N` elements |

`N` is a positive integer literal or integer macro; a flexible-array count
may also be zero. The storage is declared where the statement stands and has
C block lifetime. Every byte of it is zeroed each time the declaration runs,
so a loop body starts every iteration with zeroes. Passing such a local where
a pointer is expected passes its address:

```titan
local foreign function status_of(source: *Source): int
  local result = foreign Result.new()
  if ffi.fill(source, result) ~= 0 then return -1 end
  return result.status
end
```

Every other allocation needs an object that Lua owns, and is rejected with a
diagnostic that says so: a pointer local initialized with `.new()`, a pointer
local with a dynamic or zero `.new_array` count, a scalar `.new()`, an
inferred dynamic count, and an allocation used as an argument, a return value,
an assigned value or an operand.

Indexing these locals is raw C, like every index in a foreign body: there is
no bounds check, and `#` is unavailable because nothing keeps an element
count.

### Literals and control flow

Literals in a foreign body are C values:

| Source literal | Foreign-body C type/meaning |
| --- | --- |
| `true`, `false` | target `_Bool`, emitted as 1 or 0 |
| integer numeral | fitting contextual C integer type, otherwise its unsuffixed C99 type |
| float numeral | fitting contextual C float type, otherwise C `double` |
| string literal | `const char *` with static storage |
| `nil` | contextual `NULL` for a pointer or function pointer |

Decimal integer numerals choose the first fitting `int`, `long`, or `long long`.
Hexadecimal numerals choose the first fitting `int`, `unsigned int`, `long`,
`unsigned long`, `long long`, or `unsigned long long`. Leading-zero decimal
numerals remain decimal. Thus `3000000000` can be `long` or `long long`, and
`0xFFFFFFFF` can be `unsigned int`; neither is unconditionally `int`.
Without a fitting context, unary `-` and `~` apply to the already classified
numeral, as in [C operator mode](c-ffi-expressions.md#promotions-and-mixed-titan-operands).
Without a fitting integer context, a numeral that fits none of the C99
candidate types is rejected. Integer spelling controls this decision even
when the numeral would have a Titan `float` type in an ordinary expression.

A numeric literal takes the C type expected by:

* a local declaration with an explicit C annotation;
* an assignment to a C local, field, or element;
* an argument to a C-typed parameter; or
* a return from a function with a C return type.

An integer literal, including under unary `-`, fits when its value lies within
the C integer target's range. This includes `_Bool` (written `bool`), whose
range is 0 or 1. C enum targets do not adapt: use an enumerator of that enum or
an explicit cast.

A floating literal, including under unary `-`, fits a C floating target only
when its `double` value is finite and within that target's range. Conversion
then rounds as C does: `0.1` stored into `long double` first has its `double`
value, then widens; `1e400` is infinite as a `double` and does not fit.
Integer literals adapt only to integer targets, and floating literals only to
floating targets. A non-fitting literal keeps its C99 type and uses the normal
conversion rules, so `local byte: unsigned char = 300` is rejected.

For example, `local wide: long long = 5`, a `long long` field assignment
`item.big = 6`, a call `takes_wide(9)` with a `long long` parameter, `return 10`
from a `long long` function, and `ffi.malloc(16)` all use their expected C type.
This does not propagate an expected type into C operator operands:
`local wide: long long = c_int + 1` still computes a C `int` result and
requires a cast. Numeric-`for` literal bounds use their declared C control type.

An untyped `local p = nil` has no pointee type and is rejected; write an
annotation such as `local p: *Item = nil`.

`foreign T.sizeof` and `foreign T.alignof` keep the configured C `size_t` type inside a
foreign body. They can be passed directly to `malloc`/`calloc` or stored in a
C local; the ordinary Titan `integer` conversion applies only outside foreign
bodies.

A mutable pointer local or parameter can supply its address to an exact pointer
out-parameter. For example, a local `text: const *char` passed to a C
`const char **` parameter updates `text` and preserves its pointee constness.
A const binding, captured local, or temporary cannot supply that mutable
address. Passing a pointer to `void *` still passes the pointer's value.

Conditions use C scalar truth rather than Lua truthiness. A numeric `for` uses a
C integer or floating control type and C comparison/addition. Its start, limit,
and step are evaluated once, from left to right. The compiler rejects a literal
zero step. A dynamically computed step is a trusted precondition and must be
nonzero.

## The trusted C boundary

A foreign function is inside the unsafe C boundary. Its generated body has no
implicit Lua state, GC-root frame, `setjmp` frame, or Titan error path. Pointer
field access, indexing, and function-pointer calls use raw C behavior: Titan
does not insert its ordinary FFI NULL or bounds checks. C integer overflow,
division, shifts, pointer arithmetic, casts, and other undefined or
implementation-defined cases retain C semantics.

The compiler still preserves Titan's source sequencing. Operands, callees, and
arguments are evaluated once from left to right before the generated C operation
or call, even though C would not otherwise promise argument evaluation order.

A foreign function that explicitly calls a Lua API capable of longjmp must obey
that API's C contract. The compiler does not turn such a call into `raise` and
cannot run a Titan `defer` while it unwinds.

## Generated headers

Every source module owns a compiler-generated `.ffi.h` with its ordered C
environment. A module defining foreign functions also owns a `.titan.h` with
their declarations and the direct-call helpers of local ones. Both go to the selected
[output directory](output-directory.md) with the same hierarchy as the generated
C file, or beside the source when no output directory is selected:

| Module source | C environment | Foreign-function declarations |
| --- | --- | --- |
| flat `foo/bar.titan` | `foo/bar.ffi.h` | `foo/bar.titan.h` |
| folder main `foo/bar/bar.titan` | `foo/bar/bar.ffi.h` | `foo/bar/bar.titan.h` |

A folder contributor produces no separate headers. With `--tree` and no output
directory, the headers are beside the selected external canonical source, like
generated C and objects.

The compiler prepares all needed headers before compiling any source object.
`.ffi.h` includes explicit source dependencies' `.ffi.h` files first, then
local foreign directives in module order. `.titan.h` includes its own `.ffi.h`
and needed source dependencies' `.titan.h` declarations before emitting all
foreign prototypes and then all local direct-call helpers. Generated C includes
its `.ffi.h` before its `.titan.h` when present.

Both paths are compiler-owned. An existing destination must be a regular file
whose first bytes are the exact generated marker for that header kind. Titan
refuses user-written files, wrong-kind markers, symlinks, and directories, both
during fresh compilation and when an incremental build repairs or reuses
companions after a root move. This includes source-import dependencies; the
same ownership rule protects split-unit `.priv.h` companions. Missing `.ffi.h`
and required `.titan.h` files can be regenerated. Fresh compilation publishes
replacements only after staging succeeds, and removes a stale owned `.titan.h`
when the module no longer defines foreign functions. Do not use these reserved
paths for author-written headers.

These headers are source-build artifacts, not binary interfaces. They are not
placed in `.titan.meta`, provider archives, installed SDKs, or
standard-library publication transactions. Binary consumers recover public
foreign declarations from module metadata and emit exact typed native bindings;
they do not need either generated header.

### Inline subset and function identity

Every foreign function has exactly one out-of-line definition in its module's
generated C: exported for a public function, hidden for a local one. Using a
foreign function as a C function pointer always yields that definition's
address, so within one linked image two pointers to the same function compare
equal wherever they are taken, including in source importers and in
separately compiled parts of a large module.

Direct calls to a local foreign function, from its own module or a source
importer, go through a `static inline` helper in the generated header. The
helper contains a copy of the body only when the root body consists of
optional direct local declarations followed by exactly one of:

1. one expression return;
2. one `if` whose sole `then` and required `else` each contain one expression
   return; or
3. one `if` without `else` whose sole `then` returns, followed by one expression
   return.

For every other local foreign function the helper simply calls the
out-of-line definition; that includes a body that declares a
[zeroed local](#zeroed-locals), whose storage the header could not declare
without C library headers. Direct calls to public foreign functions always
call the exported definition. The inline copy is an
optimization/header-availability rule, not a C constant-expression promise.

## Native C names and ABI

The current ABI uses C99 universal-character-name separators in generated callable
names. `_\u2133_` separates a flattened logical module from the remaining
signature, while `_\u2131_` separates a record, union, or Interface owner from
its static, constructor, variant, method, bound, or metamethod role. For
example:

```text
foo.bar + compare        -> foo_bar_\u2133_compare_titan
foo.bar + Point.move     -> foo_bar_\u2133_Point_\u2131_move_titanstatic
foo.bar + Point:move     -> foo_bar_\u2133_Point_\u2131_move_titanmethod
```

Foreign functions share the top-level native-entry family with ordinary
functions. There is no universal `titan_` prefix and no separate hexadecimal
source-private scheme. A foreign function has only the native C entry; it has
no Lua or strict entry and no module-state closure slot. Generated C retains
the UCN spellings; object and tool names contain UTF-8 `ℳ` and `ℱ`. In a
Titan traceback, an active source foreign function appears under its display
name `<module>.<name>` with its `.titan` file and line (or the no-line form on
reduced-fidelity targets), like an ordinary top-level Titan function.

The callable hierarchy, source-defined standard-library callbacks, generic
interface metadata, and affected public standard-library signatures are all
part of the current prerelease ABI 2. Function and owned type registry
identities use the current type spellings.
[Native record and union storage](nominal-storage.md) requires rebuilding
compiler, runtime, and providers together without a prerelease version bump.

## Related chapters

* [The C FFI](ffi.md) covers imported headers, C values, allocation, FAMs, and
  ownership.
* [C FFI declarations and expressions](c-ffi-expressions.md) covers C operator
  semantics and target-directed automatic storage.
* [Functions](functions.md) covers ordinary Titan functions and closures.
* [Foreign-function internals](../implementation/foreign-functions.md)
  describes checking, lowering, headers, and native naming.
