# Foreign Functions and C Callbacks

C libraries such as `qsort`, event loops, and native widget toolkits expect plain C function pointers with no implicit Lua state or Titan closure environment. Rather than dropping down to a separate `.c` file for every small callback or native entry point, Titan lets you define **foreign functions** directly in `.titan` source using a restricted, GC-free C subset.

```titan
local io = import "io"
foreign import "stdlib.h"

local foreign function compare_ints(left: const *void, right: const *void): int
  local a = (left as const *int)[0]
  local b = (right as const *int)[0]
  if a < b then return -1 end
  if a > b then return 1 end
  return 0
end

function main(args: {string}): integer
  local nums = foreign int.new_array(5)
  nums[0], nums[1], nums[2], nums[3], nums[4] = 42, 7, 19, 3, 25

  ffi.qsort(nums, #nums, foreign int.sizeof, compare_ints)

  for i = 0, #nums - 1 do
    io.print(nums[i])
  end
  return 0
end
```

A `foreign function` compiles directly to a plain C-ABI function with no `lua_State *` parameter, no GC frame, and no Titan error handler. It is **not** an adapter around a Titan closure: ordinary Titan functions and closures cannot be passed as C callbacks.

## Declaration syntax and callback types

A foreign function is a top-level declaration:

```text
[local] foreign function name(p1: C1, p2: C2): CResult
  body
end
```

Omit `: CResult` for a C `void` function. Add `local` to keep the function private to its defining module (and direct `.titan` source collaborators); omit `local` to export it to importing Titan modules and C code via the generated `.titan.h` header. Foreign declarations cannot be nested, cannot be record or union methods, and cannot have variadic `...` parameters or multiple return values.

Inside a foreign function's signature and body, write C types **without** the `foreign` prefix (`left: const *void`, `local count: size_t = 0`, `raw as *int`). Writing `foreign` on a parameter, local, or cast inside a foreign function is a syntax error; only the expression-level layout and allocation forms keep the prefix (`foreign T.new()`, `foreign T.new_array(N)`, `foreign T.sizeof`, `foreign T.alignof`).

Every parameter and optional result must be a direct C FFI type: built-in C primitives (`int`, `double`, `size_t`, `void`, …), pointers, function pointers, or complete by-value C structs and unions. Titan types (`integer`, `string`, `boolean`, `value`, Arrays, Maps, `owned`) are not allowed in foreign signatures.

Calling a foreign function uses strict C arity (missing or surplus positional arguments are errors), and supports named calls when the declaration has unique parameter names.

### Foreign function-pointer types

In ordinary Titan code, a C function-pointer type is spelled `foreign function (P1, P2): R` (or `void` for a void return); inside a `foreign type` or foreign function, omit the leading `foreign`:

```titan
foreign type IntCompare = function (const *void, const *void): int

local foreign function asc(a: const *void, b: const *void): int
  local x = (a as const *int)[0]
  local y = (b as const *int)[0]
  if x < y then return -1 end
  if x > y then return 1 end
  return 0
end

function comparator_ready(): boolean
  local cb: foreign IntCompare = asc
  return cb ~= nil
end
```

The type is already a pointer (`foreign *(function (...): ...)` is a pointer to a function pointer). Every foreign function has one canonical address across the linked image, so two pointers taken to the same function compare equal. A foreign function is a C designator, never a Titan closure: it cannot inhabit a Titan `function (...)` type, cross to Lua, or be boxed directly as a Titan callable.

## Public exports and source visibility

Exporting a `foreign function` (without `local`) makes it callable by other Titan modules via an ordinary `import`, both from ordinary Titan functions and from other foreign functions:

```titan
foreign function clamp_int(x: int, low: int, high: int): int
  if x < low then return low end
  if x > high then return high end
  return x
end

function clamped_percent(n: integer): integer
  return clamp_int(n, 0, 100)
end
```

- **Public exports** must use exportable C types ([Chapter 16](ffi.md#public-c-types-across-modules)). Compiled `.so` and `.a` providers record the exact C signature and expose the raw C address to importing Titan modules; Lua `require` cannot see or call foreign functions.
- **Local foreign functions** (`local foreign function`) stay private to their source module and direct explicit `.titan` source imports (`import "pkg.helper.titan"`). Compiled providers contain no local foreign entries.

### Generated `.titan.h` headers

Every module that defines a foreign function generates a compiler-owned `<module>.titan.h` header beside its generated C file (under `-o <dir>` when specified), alongside `<module>.ffi.h` for its C imports and `foreign type` typedefs. `.titan.h` declares the module's foreign function prototypes so explicit `.titan` source collaborators and native C code built in the same source tree can call them directly. Do not hand-edit `.ffi.h` or `.titan.h`; `titanc` owns both files and refuses to overwrite user-authored files at those paths.

## Body subset

Because a foreign function runs without a Lua state or GC frame, its body uses a dedicated, strictly C-only subset:

**Allowed:**

- parameters and C-typed locals (mutable pointers without an initializer default to `NULL`; scalars, aggregates, and all `const` locals require an initializer);
- calls to imported `ffi.*` functions, current-module foreign functions, imported public foreign functions, and `.titan`-imported local foreign functions;
- C field access, pointer/array indexing, C casts, `foreign T.sizeof`, `foreign T.alignof`, and C-mode operators;
- assignment statements and call statements;
- `do`, `if`/`elseif`/`else`, `while`, `repeat`, numeric `for` (with C numeric bounds and a nonzero step), `break`, and `return`.

**Rejected:**

- ordinary Titan module variables, functions, records, unions, methods, and builtins `L` and `M` (a foreign body can touch `lua_State *` only when an explicit C parameter or C declaration supplies one);
- `raise`, `catch`, `defer`, `case`, `for ... in`, lambdas, `{...}` constructors, `:` method calls, generic type arguments, `...`, spreads, `is`, `as string(n)`, `..`, `#`, `//`, `^`, `and`/`or`/`not`, `?`, `owned`, Arrays, Maps, and multiple returns.

### Zeroed locals

A foreign body cannot allocate Lua-owned `owned` userdata. The only allocation forms permitted inside a foreign body are direct local declarations that allocate **block-scoped automatic C storage** zeroed each time the declaration runs:

| Declaration in a foreign body | Storage |
| --- | --- |
| `local x = foreign T.new()` *(or `: T`)* | Zeroed automatic struct or union `T` |
| `local a = foreign T.new_array(N)` | Zeroed automatic `T[N]` *(positive literal or integer macro `N`)* |
| `local p: *T = foreign T.new_array(N)` *(or `: T[]`)* | Pointer to zeroed automatic `T[N]` |
| `local f = foreign F.new(N)` | Zeroed automatic FAM struct `F` with `N` trailing elements *(nonnegative literal `N`)* |

Passing a mutable local aggregate or fixed array to a C pointer parameter passes its address:

```titan
foreign import "time.h"

local foreign function default_year(): int
  local date = foreign tm.new()
  date.tm_year = 126
  return date.tm_year + 1900
end

function year(): integer
  return default_year()
end
```

Any allocation requiring GC ownership—such as a dynamic `.new_array(count)` or an allocation returned from the function—is rejected inside a foreign body.

### Literals, operators, and sequencing

Literals and operators inside a foreign body follow C99 rules directly:

- `true` and `false` have C type `_Bool` (`1` / `0`); string literals have type `const char *` with static storage; `nil` is contextual `NULL` (an unannotated `local p = nil` is rejected—annotate `local p: *int = nil`).
- Numeric literals adapt to an explicit C target type when in range (`local wide: long long = 5`, `return 0`, `ffi.malloc(16)`), and otherwise use unsuffixed C99 literal types (`int`/`long`/`long long` for decimal, including unsigned ranks for hex, `double` for floats).
- Pointer subtraction yields `ptrdiff_t`; relational and equality operators yield C `int` (`0` or `1`); `foreign T.sizeof` and `foreign T.alignof` yield C `size_t`. Conditions test C scalar truth (nonzero).
- Pointer dereferences, indexing, and C function-pointer calls emit raw C with **no NULL or bounds checks**, and C integer overflow/shift rules apply directly.
- Unlike C, Titan still guarantees strict left-to-right single evaluation of operands, callees, and arguments before each operation or call.

## Wrapping callbacks safely from Titan

Keep foreign functions small and private, and wrap the surrounding memory management and error handling in ordinary Titan functions:

```titan
local io = import "io"
foreign import "stdlib.h"

local foreign function compare_desc(left: const *void, right: const *void): int
  local a = (left as const *int)[0]
  local b = (right as const *int)[0]
  if a > b then return -1 end
  if a < b then return 1 end
  return 0
end

function sort_descending(values: {integer}): {integer}
  local n = #values
  local buf: owned int[] = foreign int.new_array(n)
  for i = 1, n do
    buf[i - 1] = values[i]
  end
  ffi.qsort(buf, n, foreign int.sizeof, compare_desc)
  local sorted: {integer} = {}
  for i = 1, n do
    sorted[i] = buf[i - 1]
  end
  return sorted
end

function main(args: {string}): integer
  local sorted = sort_descending({3, 1, 4, 1, 5, 9})
  for i = 1, #sorted do
    io.print(sorted[i])
  end
  return 0
end
```

Here `compare_desc` stays `local` and purely C, while `sort_descending` owns the GC-managed `owned int[]` scratch buffer, validates integer conversions at the Titan/C boundary, and returns an ordinary Titan `{integer}` Array.

If a C callback must invoke Titan code (for example, a browser host callback dispatched from JavaScript or a native library callback), do not call arbitrary Lua API functions from an unmanaged C thread; on the browser target, use `browser.pin` and `titan_browser_call_sync` ([Chapter 18](browser-target.md#synchronous-c-callbacks)), and for native libuv callbacks use [`import "uv"`](standard-library-uv.md).
