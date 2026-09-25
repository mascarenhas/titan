# Foreign functions

Titan can define a function with a plain C ABI directly in Titan source. This is
useful for callbacks and other small native entry points that would otherwise
need a hand-written C trampoline.

```titan
foreign import "callback_api.h"

foreign function compare(left: *Item,
                         right: *Item): int
  if left.key < right.key then return -1 as foreign int end
  if left.key > right.key then return 1 as foreign int end
  return 0 as foreign int
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
Titan signatures may also expose foreign function-pointer types built only
from those primitives and their pointers. That exports the structural C type,
not a source `foreign function` declaration; the declaration itself retains
the source-only visibility described below.

## Declaration syntax

A foreign function is a top-level declaration:

```text
foreign function name(p1: C1, p2: C2): CResult
  body
end
```

Omit the result annotation for a C `void` function:

```titan
foreign function notify(item: *Item)
  ffi.mark_notified(item)
end
```

There is no `local` form, foreign method, foreign record function, or nested
foreign declaration. A foreign function is source-private by definition; its
availability to another Titan module is described under
[Source visibility](#source-visibility).

Every parameter and the optional result must be a direct C FFI type. A complete
C struct or union can be passed or returned by value. Pointers to incomplete
objects are valid, but an incomplete object by value is not. Titan types,
including `integer`, `string`, `boolean`, and `value`, are not foreign-signature
types. `owned` views, direct array/function values, multiple results, flexible
results, and variadic parameters are also unavailable. Use a pointer in the
signature when C expects an array or callback.

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

## Source visibility

The defining module can call or take the address of its foreign functions by
name. Another module can use them only through a written explicit source-import
alias:

```titan
local bridge = import "internal.bridge.titan"

local function install()
  ffi.install_callback(bridge.callback)
end
```

This permission is direct and source-only. Source resolution without the
`.titan` marker does not grant it, and it does not propagate through an
intermediate module. A consumer of a `.so` or `.a` sees only the producer's
public Titan interface; compiled metadata contains no foreign function.
Physical co-residence in one provider and static linking do not change that
rule, and Lua cannot see foreign functions through `require`.

The source dependency's generated `.ffi.h` joins the consumer's C environment,
and its `.titan.h` supplies foreign-function declarations. C header inheritance
is transitive, but private Titan names remain available only through the direct
explicit source-import alias. See
[Visibility through explicit source imports](source-import-visibility.md).

## Body subset

A foreign body can use:

* its parameters and initialized C-typed locals;
* foreign functions in the current module;
* foreign functions reached through an explicit source import;
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

The following Titan facilities are unavailable in a foreign body:

* `raise`, `catch`, and `defer`;
* generic `for ... in` and `case`;
* lambdas, bound methods, and Titan record/union/Array/Map constructors;
* `...`, flexible results, `is`, concatenation, and Titan `and`/`or`/`not`;
* Lua-owned `.new()` and `.new_array()` allocation.

Every local must have a direct C type. A mutable local may omit its initializer
only when that explicit type admits nil, such as a C object or function
pointer; the compiler supplies `NULL`. Direct C aggregates and scalars still
need an initializer, and every const local needs an initializer. A non-void
foreign function must return one C value on every path; a void function may
fall through or use bare `return`.

### Literals and control flow

Literals in a foreign body are C values:

| Source literal | Foreign-body C type/meaning |
| --- | --- |
| `true`, `false` | target `_Bool`, emitted as 1 or 0 |
| integer numeral | target C `int` by default, or a compatible contextual C type |
| float numeral | C `double` by default, or a compatible contextual C float |
| string literal | `const char *` with static storage |
| `nil` | contextual `NULL` for a pointer or function pointer |

An untyped `local p = nil` has no pointee type and is rejected; write an
annotation such as `local p: foreign *Item = nil`.

`foreign T.sizeof` and `foreign T.alignof` keep the configured C `size_t` type inside a
foreign body. They can be passed directly to `malloc`/`calloc` or stored in a
C local; the ordinary Titan `integer` conversion applies only outside foreign
bodies.

A mutable pointer local or parameter can supply its address to an exact pointer
out-parameter. For example, a local `text: foreign const *char` passed to a C
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

Every source module owns a compiler-generated, source-adjacent `.ffi.h` with
its ordered C environment. A module defining foreign functions also owns a
`.titan.h` with their declarations and eligible inline bodies:

| Module source | C environment | Foreign-function declarations |
| --- | --- | --- |
| flat `foo/bar.titan` | `foo/bar.ffi.h` | `foo/bar.titan.h` |
| folder main `foo/bar/bar.titan` | `foo/bar/bar.ffi.h` | `foo/bar/bar.titan.h` |

A folder contributor produces no separate headers. With `--tree`, the headers
are beside the selected external canonical source, like generated C and objects.

The compiler prepares all needed headers before compiling any source object.
`.ffi.h` includes explicit source dependencies' `.ffi.h` files first, then
local foreign directives in module order. `.titan.h` includes its own `.ffi.h`
and needed source dependencies' `.titan.h` declarations before emitting all
foreign prototypes and then all eligible inline bodies. Generated C includes
its `.ffi.h` before its `.titan.h` when present.

Both paths are compiler-owned. Titan refuses to overwrite an unowned path,
replaces a prior generated header only after staging succeeds, and removes a
stale owned `.titan.h` when the module no longer defines foreign functions.
Do not use either reserved path for an author-written header.

These headers are source-build artifacts, not binary interfaces. They are not
placed in `.titan.meta`, provider archives, installed SDKs, Lua shims, or
standard-library publication transactions. A binary consumer cannot recover or
name the foreign functions they declare.

### Inline subset and function identity

A foreign function is emitted as `static inline` in the generated header only
when its root body consists of optional direct local declarations followed by
exactly one of:

1. one expression return;
2. one `if` whose sole `then` and required `else` each contain one expression
   return; or
3. one `if` without `else` whose sole `then` returns, followed by one expression
   return.

Every other foreign function has a hidden external definition in the module's
generated C file. The inline form is an optimization/header-availability rule,
not a C constant-expression promise. Taking one inline function's address in
two translation units may yield different addresses.

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
the UCN spellings; object and tool names contain UTF-8 `ℳ` and `ℱ`.

The callable hierarchy, source-defined standard-library callbacks, generic
interface metadata, and affected public standard-library signatures are all
part of the current prerelease ABI 2. Function and owned type registry
identities use the revised type spellings. The earlier grammar change did not
require an independent ABI or language-version change.
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
