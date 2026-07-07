# The Titan language

Titan is a statically-typed, ahead-of-time-compiled sister language to
[Lua](https://www.lua.org). Titan modules compile to native code that runs
inside the Lua runtime: Lua programs `require` them like any other module,
call their functions, and share data with them directly. Titan's syntax
and semantics are deliberately close to a subset of Lua — a Lua programmer
can read Titan on first sight — but every variable has a static type, and
the compiler uses those types to generate code that works on Lua values
at C speed, with none of the dynamic dispatch of the Lua VM.

```lua
-- sum.titan
function sum_list(xs: {integer}): integer
    local sum: integer = 0
    for i = 1, #xs do
        sum = sum + xs[i]
    end
    return sum
end
```

```lua
-- Lua
local m = require "sum"
print(m.sum_list({1, 2, 3, 4})) --> 10
```

This is the reference for the language as implemented by the Titan 0.11
prototype compiler in this repository. It replaces the old single-file
manual. For how the compiler itself works — including how each construct
is translated to C — see the
[implementation documentation](../implementation/index.md).

## Reading guide

Start with the [design philosophy](philosophy.md) if you want to know
*why* Titan is shaped the way it is; start with the
[type system](types.md) if you want to learn the language.

| Chapter | Covers |
| --- | --- |
| [Design philosophy and history](philosophy.md) | Why Titan exists, its core commitments, the project's history and design principles. |
| [The type system](types.md) | All Titan types; type equality, compatibility and implicit coercions; type inference; the dynamic `value` type. |
| [Option types](option-types.md) | `T?`: nil-tolerant types — syntax, semantics, defaulting with `or`, and how `nil` flows through arrays, maps, and the Lua boundary. |
| [Expressions](expressions.md) | Literals and escapes, operators and precedence, Lua-faithful arithmetic, concatenation, `and`/`or`, explicit casts with `as`, constructors, calls. |
| [Statements](statements.md) | Declarations and inference, assignment and multiple assignment, control flow, the numeric `for`, `return`. |
| [Functions](functions.md) | Declarations, argument adjustment, multiple return values, visibility, functions as values, and the `main` convention for standalone programs. |
| [Anonymous functions and closures](closures.md) | Lambda expressions, parameter/return type inference, lexical capture of enclosing locals, fresh-value-per-evaluation semantics, and bound method references `obj:method`. |
| [Variadic parameters](variadic-parameters.md) | The trailing `...: t` parameter, `#...`, the raising `...[e]` index, spreading `...` into calls/returns/arrays, slot-driven adjust-up, variadic functions as values, and the limits and bans. |
| [Records](records.md) | Nominal record types, constructors, fields, methods, record functions, and records as seen from Lua. |
| [Arrays and maps](arrays-maps.md) | The two table-backed container types: construction, indexing, length, deletion, key rules, performance model. |
| [Modules](modules.md) | Module files, `import`, visibility, module variables, and the compilation model (shared libraries, executables, search paths). |
| [Lua interoperability](lua-interop.md) | Using Titan from Lua and Lua values in Titan: what crosses the boundary, what each type looks like on the other side, and where the run-time checks happen. |
| [Error handling](error-handling.md) | The run-time error model: what raises errors, error messages, `pcall`, `titan.backtrace()`, and the option-type idiom for recoverable failures. |
| [The C FFI](ffi.md) | `foreign import`: binding C headers, supported types, calling C functions, limitations. |
| [Grammar](grammar.md) | The complete lexical and syntactic grammar. |

## Status and limitations

Titan is a working prototype, version 0.11. The language documented here is
implemented and covered by the compiler's test suite. Its boundaries are
mostly missing features, plus a handful of constructs the compiler rejects
with a clean error; each links to the chapter that documents it in full.

### First-class functions

* **Functions are first-class values.** A function name — a top-level
  function, a `local` function, an imported module's function, or a record
  static like `Rec.new` — used as a value yields a stable function value,
  and function types like `(integer) -> integer` are accepted in every
  type position. Function values can be stored in locals, parameters,
  record fields, arrays and maps, passed, returned, and called; exact
  Titan-to-Titan calls take a zero-overhead fast path, other callables a
  generic one
  ([functions](functions.md#functions-as-values),
  [type system](types.md#function-types)). This also means Titan can
  **call a Lua function directly** — passing a Lua closure to a
  function-typed parameter and calling it
  ([Lua interop](lua-interop.md#calling-lua-from-titan)).
* **Anonymous functions and closures.** A `function (...) ... end`
  expression evaluates to a fresh function value, and it **closes over**
  the enclosing function's locals and parameters — reading them, and
  mutating them through a shared box when it assigns to them. Lambda
  parameter and return types are *inferred* (from the expected type and
  from the body) the same way `local x = exp` infers a local's type
  ([closures](closures.md)).
* **Bound instance methods are values too.** `obj:method` with no argument
  list is a function value that has the method's type with the implicit
  `self` removed, bound to the receiver — so a method *can* now be taken
  as a value ([closures](closures.md#bound-method-references),
  [records](records.md#methods)).
* **What is still not first-class.** Foreign/FFI functions are not Titan
  function values: a C function can be called by name or converted to a
  compatible C function pointer, but cannot be stored as a Titan function value
  ([the FFI chapter](ffi.md)).

### Smaller gaps and rough edges

* **No `goto`, no `for ... in`** — these two words are reserved but unused:
  there is no generic `for ... in` loop and no `goto`/labels, so using
  them is a syntax error. `break` *is* supported (and a loop can also be
  exited with `return`)
  ([statements](statements.md#break-no-goto)).

### The C FFI

* **The FFI imports real C types, fields, arrays and owned objects**, and
  is the one place Titan's safety guarantees end — a C function can misuse
  memory and crash the process, and a Titan `string` handed to a C
  function that frees or stores it corrupts the heap. Imported C types are
  distinct from Titan types, can be used in local annotations, and support
  regular `as <type>` casts; they cannot be exported from Titan modules.
  C arrays are 0-based (`T[N]` bounds-checked, pointers unchecked, counted
  owned arrays dynamically checked), `#` works for static/count-owned
  arrays, struct/union fields can be read and written, and `.new()` /
  `.new_array(count)` allocate zeroed Lua-GC-owned userdata with no
  finalizer. Explicit C variadic calls are supported; Titan functions cannot yet be
  passed to C, adopted lifetimes are parked, and owned structs with
  flexible array members are deliberately rejected for this version
  ([the full list](ffi.md#current-limitations)).

### Other

* **Error handling is intentionally small.** Titan has `raise`,
  `catch`, and `finally`, but errors are still plain Lua values plus an
  out-of-band traceback: there is no exception class hierarchy and no
  chaining/cause mechanism. A new error in a catch or finally replaces the
  previous one ([error handling](error-handling.md)).
* **No standard library yet.** Titan code uses the FFI, imported Titan
  modules, or its Lua host for library functionality.

The [README roadmap](../../README.md) lists where the language is headed;
the [philosophy chapter](philosophy.md) explains the principles that order
that list.
