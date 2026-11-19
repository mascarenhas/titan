# Calling C: The Foreign Function Interface

Titan calls C functions, reads C constants and variables, and works with C structs, pointers, and arrays directly from C headers parsed at **compile time**:

```titan
foreign import "stdio.h"

function greet(name: string): integer
  return ffi.printf("Hello, %s!\n", name)
end
```

A foreign call compiles to a direct C call in the generated translation unit—there is no dynamic reflection layer or `libffi` overhead. Because C operations emit direct native code, treat `foreign import`, `foreign function` bodies, and raw-pointer handoffs as an explicit **unsafe boundary**, comparable to Rust's `unsafe`. Pure Titan code is memory- and type-safe; once you cross into C, your code and the C libraries it calls are responsible for pointer validity, lifetimes, ownership, ABI compatibility, and thread safety. Keep FFI usage isolated inside a small owner module and expose ordinary Titan types to the rest of your program.

## Importing headers

`foreign import` is a top-level directive that adds a header's C declarations to the module's compile-time `ffi` namespace:

```titan
foreign import "limits.h"
foreign import "stdlib.h"

const max_signed_64: integer = ffi.LLONG_MAX as integer
local magnitude: integer = ffi.abs(-7)

function abs_diff(a: integer, b: integer): integer
  return ffi.abs((a - b) as foreign int)
end
```

All `foreign import` directives in a module are preprocessed and parsed together in one ordered C environment (in folder modules: the selected main file first, then selected contributors in logical filename order; explicit `.titan` source imports prepend their `.ffi.h` C environment first). `#pragma once`, `#ifndef` include guards, macro definitions, and `#undef` operate across the full chain, and the resulting `ffi` namespace is visible throughout the module—including in module-variable initializers written above a directive.

`ffi` is a compile-time namespace, not a runtime value: it cannot be stored, passed, returned, or assigned. An ordinary local or declaration may shadow the `ffi` term binding without affecting foreign type resolution.

### Header resolution

Header lookup follows standard C include intent:

- **Absolute paths** (`"/opt/lib/api.h"`) are read directly and emitted as quoted includes.
- **Relative paths beside the source** (`"widget.h"` in the same directory as the canonical `.titan` file) resolve there as quoted includes, preserving nested relative includes.
- **`"titan/ffi.h"`** resolves from the active Titan SDK's `include` directory and exposes the opaque `lua_State`, `TValue`, and `Udata` declarations.
- **Other relative names** (`"stdio.h"`, `"sys/stat.h"`) resolve as system angle headers (`#include <...>`).

Pass additional include directories and preprocessor defines with `titanc -I <dir> -D <name[=val]>` (or `TITAN_EXTRA_CPPFLAGS`).

### Imported members

An imported C environment populates two separate namespaces—values under `ffi.*` and types under `foreign ...`:

- **Functions:** Prototypes and header-defined `static` or `inline` functions become callable `ffi.<name>` members, including C variadic functions like `printf` and `snprintf`.
- **Variables and arrays:** `extern` C variables and arrays are readable via `ffi.<name>`. Direct assignment to a foreign variable name (`ffi.x = 1`) is rejected; write through an array index, pointer, or struct field (or a C setter).
- **Enum constants and object-like macros:** Top-level enum constants and recognized object-like `#define` macros appear as `ffi.<name>`.
- **Types:** Typedef names and named file-scope `struct`/`union` tags appear in the foreign type namespace.

Because C value and type namespaces are distinct, a header that declares both a `struct stat` and a function `stat(...)` works cleanly: `ffi.stat(...)` calls the function, while `foreign stat.new()` and `foreign stat.sizeof` refer to the struct tag. Member selectors and foreign type names accept reserved Titan keywords, so C fields or functions named `type`, `when`, `repeat`, or `interface` remain usable as `ffi.type` or `obj.repeat`.

## C types in Titan

Built-in and imported C types stay distinct C types rather than becoming aliases for Titan `integer` or `float`. Where Titan and C types are both allowed (annotations, casts, record fields), prefix a C type with `foreign`. Inside a foreign type constructor or `foreign function` signature/body, write the C spelling unqualified.

The built-in C primitives require no `foreign import`:

```text
void          bool          char            signed char       unsigned char
short         unsigned short               int               unsigned int
long          unsigned long                long long         unsigned long long
float         double        long double
```

Here `bool` is C99 `_Bool` (not Titan `boolean`), and sizes, ranks, and signedness come from the configured C compiler's target profile. These words remain ordinary identifiers outside foreign type syntax, so a Titan record or local named `int` is still valid.

| C family | Titan spelling | Notes |
| --- | --- | --- |
| `void` | `foreign void` | Return type of void C calls and `foreign *void` pointee |
| Integers & floats | `foreign int`, `foreign double`, … | Distinct exact C numeric types |
| Object pointer `T *` | `foreign *T`, `foreign const *T` | Nullable; pointee must be a C type (never `foreign *integer`) |
| Function pointer | `foreign function (P...): R`, or typedef | Nullable; already a pointer (`foreign *(function(...): ...)` is pointer-to-pointer) |
| Fixed array `T[N]` | Inferred via `foreign T.new_array(N)` | Positive literal/macro extent; no written `T[N]` syntax |
| Uncounted array view | `foreign T[]` | Borrowed element pointer at local sinks or nominal fields |
| `struct S`, `union U` | `foreign S`, `foreign U` | Typedef name or file-scope tag; unrelated to Titan `union` |
| GC-owned C object | `owned *T` | One zeroed GC-managed C `T` |
| GC-owned C array | `owned T[]` | Dynamically counted GC-managed array of C `T` |
| Lua runtime value | `foreign TValue`, `foreign *Udata` | Requires `foreign import "titan/ffi.h"`; GC-traced |

Group nested foreign constructors explicitly: `foreign *(*int)` for `int **`, and `owned (*int)[]` for an owned array of `int *`.

### Named `struct` and `union` tags

Named file-scope `struct` and `union` tags are usable directly through `foreign Tag` even without a C `typedef`:

```titan
foreign import "time.h"

function year_label(): integer
  local calendar = foreign tm.new()
  calendar.tm_year = 126
  return (calendar.tm_year as integer) + 1900
end
```

If a header declares both a `typedef` and a `struct`/`union` tag with the same spelling, the `typedef` takes precedence. Incomplete forward declarations (`struct Opaque;`) publish `foreign Opaque` for pointers only; by-value use, field access, allocation, and `sizeof` require the complete definition. Anonymous aggregates and nested prototype-scoped tags are not published.

### Layout queries: `sizeof` and `alignof`

`foreign T.sizeof` and `foreign T.alignof` evaluate C's `sizeof(T)` and `_Alignof(T)` and convert the target `size_t` to Titan `integer` (range-checked):

```titan
function int_layout(): (integer, integer)
  return foreign int.sizeof, foreign int.alignof
end
```

Inside a restricted `foreign function` body, both keep their raw C `size_t` type.

### Local C typedefs (`foreign type`)

`foreign type Name = foreigntype` declares a module-local C `typedef` (without a `local` modifier):

```titan
foreign type IntPtr = *int
foreign type Comparator = function (const *void, const *void): int
local type OwnedInt = owned IntPtr

function make_int(n: integer): OwnedInt
  local box: OwnedInt = foreign int.new()
  local ptr: foreign IntPtr = box
  ptr[0] = n
  return box
end
```

Forward references between `foreign type` declarations are resolved in dependency order; cycles and C name collisions are rejected. `foreign type` definitions are emitted in the module's `.ffi.h` and inherited by explicit `.titan` source imports (not ordinary or binary imports). Ownership (`owned`) is a Titan type constructor and cannot appear on the right-hand side of a `foreign type`.

### Public C types across modules

Public function signatures, record fields, and union parts may expose C types whenever their full type graph is exportable: built-in primitives, pointers, `foreign *lua_State`, function pointers, eligible `owned` types, and named header typedefs, structs, unions, or fixed arrays (provided embedded aggregates are complete, non-GC, and contain no flexible array member). Enum identities and unnamed aggregates without a typedef remain private.

If a public signature uses header-dependent C types, every importing module must include the original compatible C headers with its own `foreign import`—ordinary imports carry layout and type metadata, not C headers. When designing a header-free public module, convert C values into ordinary Titan records, strings, and numbers at the module boundary.

## Calling C functions

Direct calls to imported C functions use **strict C arity**: missing or surplus positional arguments are compile errors. A trailing multi-result Titan call or spread may supply the exact remaining fixed arguments, while runtime-open flexible tails cannot cross into C.

When a nonvariadic C prototype provides a complete list of unique parameter names, Titan also supports named-call syntax using the exact C parameter names (omitted parameters pass `nil`, which succeeds for pointers and fails for required scalars). Old-style `f()`, unnamed prototypes, C variadics, and C function-pointer calls are positional-only.

For C variadic functions (`printf`, `snprintf`), Titan checks the fixed prefix and passes explicit trailing arguments using their static types and C default promotions. Cast numeric variadic arguments to the exact C type expected by the format string, because Titan `integer` maps to `lua_Integer`:

```titan
foreign import "stdio.h"

function format_count(n: integer): string
  local buf: owned char[] = foreign char.new_array(32)
  local written: integer = ffi.snprintf(buf, 32, "count=%lld", n as foreign long long)
  if written < 0 then raise "snprintf failed" end
  local ptr: foreign *char = buf
  return ptr as string
end
```

Titan `...` varargs and collection spreads cannot supply C `...` arguments.

Imported C functions are not Titan first-class functions: `ffi.abs` cannot be stored in a Titan `function (integer): (integer)` variable. It can only be called directly or converted to an exact compatible C function-pointer type. Calling through a C function-pointer value raises if it is `NULL`. To pass a callback written in Titan to a C API, write a restricted [`foreign function`](foreign-functions.md).

## Casts and coercions

At typed sinks (annotated locals, assignments, arguments, returns), Titan inserts direct C conversions automatically. Use explicit `as` only when switching operator semantics, choosing a C variadic argument type, copying a C pointer to a Titan `string`, or making an unsafe raw-pointer assertion.

| Conversion | Form | Behavior |
| --- | --- | --- |
| C integer ↔ Titan `integer` | Direct or `as` | Range-checked against target profile / `lua_Integer`; `_Bool` accepts only `0` or `1` |
| C float ↔ Titan `float` | Direct or `as` | Range-checked when narrowing; preserves finite values, NaNs, and infinities on widening |
| C integer ↔ C integer | Written `as` | Preserves C signed/unsigned conversion semantics |
| C pointer (object or fn) → `boolean` | Direct or `as` | `NULL` is `false`, non-`NULL` is `true` |
| `nil` → C pointer | Direct or `as` | Typed `NULL` pointer |
| C array or `owned T[]` → `foreign *T` | Direct or `as` | Decays to element pointer (adding qualifiers allowed; discarding forbidden) |
| Object pointer → `foreign *void` | Direct or `as` | Qualification-preserving |
| `foreign *void` → non-char `foreign *T` | Direct or `as` | Qualification-preserving; `foreign *char` requires written `as` |
| C fn pointer ↔ `foreign *void` | Written `as` only | Toolchain portability cast (direct object-ptr ↔ fn-ptr cast is rejected) |
| Mutable C local/formal `T` → `foreign *T` | Direct call arg | Passes address of local storage for C out-parameters (`const`/temporaries rejected) |
| Mutable C pointer local `*T` → `foreign *(*T)` | Direct call arg | Passes address of pointer local preserving qualifiers |
| By-value C expression `T` → `foreign const *T` | Direct call arg | Materializes read-only address for the duration of the call |
| Titan `string` → `foreign const *char` / `*void` | Direct call arg | Zero-copy borrowed byte pointer valid only during the call |
| `foreign *char` / `*void` → `string` | Written `as string` | NULL-checked copy through first `\0` |
| Byte/void pointer → `string` | Written `as string(n)` | Binary copy of exact `n` bytes |
| `owned char[]` (signed/unsigned/plain) → `string` | Written `as string` | Binary copy of exact allocated length |
| C scalar, pointer, or `owned` → `value` | Direct or `as` | Scalars range-checked; raw pointers box as lightuserdata; `owned` stays full userdata |
| `value` → raw `foreign *T` / fn pointer | Written `as` / `is` only | Unsafe lightuserdata/nil assertion (cannot verify pointee or signature; implicit rejected) |
| Array, Map, record, union, Interface, function → `foreign *void` | Written `as` only | Exposes borrowed internal runtime GC object address (do not dereference or free) |

C scalars stay in their exact C types until a typed boundary converts them. Every partial written cast has an `is` predicate twin (`e is T`) that evaluates `e` once and tests whether `e as T` would succeed without raising or narrowing the static type.

**Contextual object-pointer conversions:** C APIs often pass related struct pointers through a common base pointer (such as `Widget *` to `Object *`). Where a typed sink supplies the destination pointer type, Titan accepts the directional object-pointer conversion and asks the C compiler to validate it (qualifiers may be added, never discarded).

**Options do not chain conversions:** Titan performs one outer conversion per sink. Passing `(owned *int)?` directly to a `foreign *int` parameter is rejected; unwrap into a typed `owned *int` local first:

```titan
local function read_optional(maybe: (owned *int)?): integer
  if maybe == nil then return 0 end
  local box: owned *int = maybe
  local ptr: foreign *int = box
  return ptr[0]
end
```

## C operators, constants, and expressions

When at least one operand of an arithmetic, bitwise, or comparison operator is a C scalar, pointer, or array, Titan evaluates the operator in **C mode**:

| Operator | C-mode operands | Result |
| --- | --- | --- |
| `-x`, `~x` | C numeric / C integer | Promoted C type |
| `a + b`, `a - b` | Numeric pair; complete object pointer ± integer; compatible object pointer difference | Usual C arithmetic type, pointer, or checked Titan `integer` (pointer diff) |
| `a * b`, `a / b`, `a % b` | Numeric pair (`%` integer only) | Usual C arithmetic type |
| `a & b`, `a \| b`, `a ~ b` | C integer pair (`~` is C XOR `^`) | Usual C arithmetic type |
| `a << b`, `a >> b` | C integer pair | Promoted left C integer type |
| `<`, `<=`, `>`, `>=` | Numeric pair or compatible object pointers | Titan `boolean` |
| `==`, `~=` | Numeric pair; object/`void` pointers; pointer and `nil`; matching fn pointers | Titan `boolean` |

`//`, `^`, `and`, `or`, `not`, `..`, and `#` remain Titan operations and never enter C mode.

C-mode operators emit direct C operations with C promotions, C signed/unsigned rules, truncating integer division, and C undefined behavior on signed overflow or invalid shifts:

- An unsuffixed decimal literal next to a C operand takes its C99 type (`int`, `long`, or `long long`); a hexadecimal literal tries unsigned ranks too; a floating literal takes `double`. Thus `c_int + 1` computes in C `int`, not 64-bit Titan `integer`.
- A non-literal Titan `integer` or `float` participates as `lua_Integer` or `lua_Number`.
- When you want Titan's wrapping arithmetic, floor division, or range-checked stores, cast to Titan `integer` *before* the operator:

```titan
foreign import "errno.h"
foreign import "math.h"
foreign import "signal.h"
foreign import "stdlib.h"

function c_vs_titan(): (integer, integer, float, boolean)
  local c_quot: integer = ((-7 as foreign int) / (3 as foreign int))
  local titan_quot = (-7) // 3
  local missing: integer = ffi.ENOENT
  local different_handlers = ffi.SIG_IGN ~= ffi.SIG_DFL
  return c_quot + missing * 0, titan_quot, ffi.INFINITY, different_handlers
end
```

### Macros and projected fields

Supported object-like macros include integer and floating constant expressions, standard `<math.h>` constants (`INFINITY`, `NAN`, `HUGE_VAL`), typed dereferenced accessors (such as `errno`), outer casts to C scalars or pointers (such as `SIG_IGN`), single declared-identifier aliases (such as POSIX `stdout`), and pure dotted field projections (`#define st_mtime st_mtim.tv_sec`). Generated C preserves the public macro name so the native C compiler expands it under the same headers.

Function-like macros are not imported; when a real C function shares the name, `ffi.<name>` calls the function directly.

### C assignment receivers and order

C field and index assignments follow Titan's left-to-right target-preparation order: receivers and indices are evaluated and frozen before the right-hand side, then the final NULL or bounds check and store execute. Intermediate checks needed to reach a target run before the right-hand side.

An assignment target that mutates a by-value C struct, union, or array must denote **persistent storage** (a local, parameter, imported variable, or pointer/owned dereference). Mutating a field on a temporary returned by value is rejected, while reading a pointer field from that temporary and mutating its pointee is allowed:

```text
local d = ffi.div(17, 5)
d.quot = 4                      -- ok: d is persistent local storage
ffi.div(17, 5).quot = 4         -- compile error: temporary by-value C aggregate
```

## Strings, pointers, and counted byte copies

Passing a Titan `string` to a C `char *` or `void *` parameter passes a pointer to its internal immutable bytes with zero copying. Titan keeps the string rooted for the duration of the call; C must not store, mutate, free, or reallocate that pointer.

Converting a C `char *` or `void *` to a Titan `string` with `ptr as string` checks non-NULL and copies through the first `\0` byte. Raw C pointers are nullable, test truthy when non-NULL, and are never owned by Titan—pair C-allocated handles with `defer` immediately after acquisition:

```titan
foreign import "stdio.h"
foreign import "stdlib.h"

function env_var(name: string): string?
  local raw = ffi.getenv(name)
  if not raw then return nil end
  return raw as string
end

function file_exists(path: string): boolean
  local handle = ffi.fopen(path, "r")
  if not handle then return false end
  defer ffi.fclose(handle)
  return true
end
```

### Counted byte copies

When native memory holds binary data with an explicit byte length (possibly containing NUL bytes), use `pointer as string(length)`:

```titan
function copy_binary(): string
  local bytes = foreign unsigned char.new_array(4)
  bytes[0] = 65
  bytes[1] = 0
  bytes[2] = 66
  bytes[3] = 0
  local ptr: foreign *unsigned char = bytes
  return ptr as string(4)
end
```

- Accepted sources are pointers to `char`, `signed char`, `unsigned char`, or `void` (including typedefs and qualifiers).
- `length` must be a Titan or C integer, range-checked against `size_t` and Lua's maximum string length.
- `length == 0` returns `""` without dereferencing the pointer (even when `NULL`); positive length with `NULL` raises.
- `pointer is string(length)` evaluates pointer then length and tests count bounds and zero-or-non-NULL without reading bytes or allocating (`NULL is string(0)` is `true`, whereas `NULL is string` is `false`).
- Note that parentheses continue a counted cast across a newline; place `;` before a separate parenthesized-call statement.

For a counted GC-owned byte array (`owned char[]`, `owned signed char[]`, or `owned unsigned char[]`), `bytes as string` directly copies its exact allocated length without scanning for NUL.

## Automatic storage, owned C objects, and arrays

C indexing is **0-based**:

- Raw C pointers and uncounted `foreign T[]` views are NULL-checked, with **no bounds check** and no `#`.
- Fixed automatic C arrays, counted `owned T[]`, and flexible-array members with live provenance are **bounds-checked** and support `#array`.

### Owned C objects

`foreign T.new()` and `foreign T.new_array(count)` allocate zeroed C storage. At a direct local declaration, the target type chooses between stack-allocated automatic storage and GC-managed `owned` userdata:

| Declaration | Storage representation |
| --- | --- |
| `local x = foreign T.new()` *(struct/union `T`)* | Automatic block-local `foreign T` |
| `local x: foreign T = foreign T.new()` | Automatic block-local `foreign T` |
| `local x: owned *T = foreign T.new()` | GC-owned `owned *T` userdata |
| `local x: foreign *T = foreign T.new()` | Pointer into a hidden frame-rooted owner |
| `local a = foreign T.new_array(N)` *(positive literal/macro `N`)* | Automatic fixed C array `T[N]` |
| `local a: owned T[] = foreign T.new_array(n)` | Counted GC-owned `owned T[]` userdata |
| `local p: foreign *T = foreign T.new_array(n)` / `foreign T[]` | Borrowed pointer view (automatic for constant `N`, hidden owner for dynamic `n`) |
| Other expressions (returns, arguments, module variables) | `owned *T` or `owned T[]` |

```titan
function owned_examples(count: integer): (integer, string)
  local fixed = foreign int.new_array(4)
  fixed[0] = 10

  local dynamic: owned int[] = foreign int.new_array(count)
  if #dynamic > 0 then
    dynamic[0] = fixed[0]
  end

  local raw: owned char[] = foreign char.new_array(3)
  raw[0] = 65 as foreign char
  raw[1] = 0 as foreign char
  raw[2] = 66 as foreign char
  return #fixed + #dynamic, raw as string
end
```

Key ownership and lifetime rules:

- `owned *T` and `owned T[]` are full Lua userdata freed by GC when unreachable, with **no automatic resource finalizer** (attach `gc.finalizable` or use `defer` if a C handle needs explicit teardown).
- Outer `const` on an owned type (`owned const *int`, `owned const int[]`) is rejected.
- Automatic storage has C block lifetime; never return or store a pointer to it past its block. A pointer borrowed from an `owned` local stays valid only while the owner remains reachable—if a pointer outlives an `if` block that allocated an `owned` buffer, declare an optional `(owned T[])?` slot in the outer block to keep it rooted.
- Mutable C pointer locals may omit their initializer and default to `NULL` (`local p: foreign *int`). Direct structs, unions, scalars, fixed arrays, and all `const` locals require an initializer.
- A `const` local holding an inline C struct, union, or fixed array cannot have its inline fields/elements mutated or its mutable address taken. Across a pointer or `owned` binding, Titan `const` is shallow: it prevents reassigning the binding, while C `foreign const *T` controls pointee mutability.

### Flexible-array-member allocation

For a complete C struct `T` ending in a flexible array member `E items[]`, allocate an extended object with `foreign T.new(count)` (zeroing `max(sizeof(T), offsetof(T, items) + count * sizeof(E))`, with overflow checking):

```text
-- Given: struct Packet { int kind; int items[]; };
local stack_pkt = foreign Packet.new(8)                 -- literal automatic extent
local heap_pkt: owned *Packet = foreign Packet.new(n)   -- dynamic GC-owned extent
local len = #heap_pkt.items                             -- n (bounds-checked)
```

`foreign T.new()` without a count and `foreign T.new_array(...)` are rejected for FAM structs. Converting the parent to a raw `foreign *Packet` erases count provenance, removing `#` and bounds checks on the flexible member.

### C storage after a caught error

Locals and parameters whose mutable C address was exposed (via an out-parameter, pointer-to-pointer out-parameter, or array decay) keep a single stable storage home across `raise` and `catch`. When a C or Titan callee writes through that address before raising, `defer` and `catch` blocks observe those writes rather than a stale pre-call value.

## Native C storage in records and unions

Titan records and unions can store native C scalars, pointers, and complete non-GC C structs, unions, and fixed arrays directly inside the nominal userdata without boxing each field as a Lua value.

### Embedding fixed C objects

Constructing a record or union copies a fixed C struct, union, or fixed array into the nominal object. Reading the field (or binding the union part in `case`) projects a **borrowed pointer** to the interior storage without allocating:

```titan
foreign import "stdlib.h"

local record Division
  const result: foreign div_t
end

function remainder_of(num: integer, den: integer): integer
  local entry = Division(ffi.div(num, den))
  local ptr = entry.result          -- foreign *div_t (borrowed interior pointer)
  return ptr.rem
end
```

Keep the owning record or union reachable for as long as a borrowed interior pointer is used. Field `const` is shallow: `entry.result = other` is rejected, while writing through a mutable interior pointer (`entry.result.rem = 0`) is permitted unless the C field type itself is `const`.

### Trailing fresh buffers in the owner's allocation

When a direct generated record constructor or union variant constructor passes a fresh `foreign T.new_array(n)` or `foreign Packet.new(n)` directly to a `const` pointer/array field (`foreign T[]` or `foreign *Packet`), Titan places the zeroed buffer inside the same single userdata allocation as the nominal owner:

```titan
record IntBuffer
  const length: integer
  local const data: foreign int[]
end

function IntBuffer.make(len: integer): IntBuffer
  return IntBuffer(len, foreign int.new_array(len))
end

function IntBuffer:get(index: integer): integer
  if index < 1 or index > self.length then raise "index out of bounds" end
  return self.data[index - 1]
end

function IntBuffer:set(index: integer, val: integer)
  if index < 1 or index > self.length then raise "index out of bounds" end
  self.data[index - 1] = val
end
```

Keep the fresh allocation expression directly inside the generated constructor call (positional or named). Initialize native C handles that store self-referential pointers *after* constructing the owning record, never before copying into it.

### Exact native numeric fields

Foreign numeric fields and optional foreign numbers preserve their full C precision inside Titan records, locals, and calls, performing range checks only when crossing into a narrower type or a boxed boundary (Lua, `value`, Array/Map slots, reflection, or JSON):

```titan
foreign import "limits.h"

record WideCounter
  count: (foreign unsigned long long)?
end

function max_counter(): WideCounter
  return WideCounter(ffi.ULLONG_MAX)
end

function is_at_max(counter: WideCounter): boolean
  if counter.count == nil then return false end
  return (counter.count as foreign unsigned long long) == ffi.ULLONG_MAX
end
```

## The built-in Lua state

Inside every ordinary Titan function, method, lambda, and module initializer, the readonly builtin `L` provides the current call's `foreign *lua_State`, and `M` identifies the current module (`M as foreign *Udata` with `foreign import "titan/ffi.h"`):

```text
foreign import "lua_helpers.h"
-- int current_stack_top(lua_State *L);

function stack_top(): integer
  return ffi.current_stack_top(L)
end
```

Pass `L` only to C helpers that use it during the call; never save or return `L`, and never re-enter an active ancestor Lua thread directly with `lua_call`/`lua_pcall` (see [unwinding limits](coroutines.md#unwinding-limits)). Source-defined `foreign function` bodies receive neither `L` nor `M`.

## Linking C libraries and limitations

`foreign import` supplies C declarations; link the corresponding implementation with `titanc` flags:

```sh
titanc -o out -I /opt/widget/include -L /opt/widget/lib -l widget app.main
titanc -o out --c-source shim.c app.main
```

See [Appendix B](toolchain.md) for all native compiler/linker flags (`-I`, `-D`, `-L`, `-l`, `--cflag`, `--ldflag`, `--c-source`, `-X`). When building against Titan's standard library, use the public [`import "uv"`](standard-library-uv.md) module rather than embedding a second copy of `libuv` or `lpeglabel`.

FFI limitations:

- **No automatic closure adaptation:** Imported C functions and `foreign function` entries are not Titan closures, and ordinary Titan closures cannot be passed as C function pointers; write a restricted [`foreign function`](foreign-functions.md) for C callbacks.
- **No function-like macros:** Only functions, variables, enums, typedefs, tags, and supported object-like macros are imported. Write a tiny `static inline` wrapper in a header or `--c-source` file when a C API relies on a function-like macro.
- **No adopting external allocations:** Titan cannot transfer `malloc`-allocated pointers into GC ownership; use `defer ffi.free(p)` or `owned` storage instead.
- **Bounded C99/GNU/Clang parser:** Headers relying on exotic compiler extensions may need a small wrapper header exposing the clean C99 declarations Titan needs.
