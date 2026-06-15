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

This is the reference for the language as implemented by the Titan 0.5
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
| [Functions](functions.md) | Declarations, strict arity, multiple return values, visibility, and the `main` convention for standalone programs. |
| [Records](records.md) | Nominal record types, constructors, fields, methods and statics, and records as seen from Lua. |
| [Arrays and maps](arrays-maps.md) | The two table-backed container types: construction, indexing, length, deletion, key rules, performance model. |
| [Modules](modules.md) | Module files, `import`, visibility, module variables, and the compilation model (shared libraries, executables, search paths). |
| [Lua interoperability](lua-interop.md) | Using Titan from Lua and Lua values in Titan: what crosses the boundary, what each type looks like on the other side, and where the run-time checks happen. |
| [Error handling](error-handling.md) | The run-time error model: what raises errors, error messages, `pcall`, `titan.backtrace()`, and the option-type idiom for recoverable failures. |
| [The C FFI](ffi.md) | `foreign import`: binding C headers, supported types, calling C functions, limitations. |
| [Grammar](grammar.md) | The complete lexical and syntactic grammar. |

## Status and limitations

Titan is a working prototype, version 0.5. The language documented here is
implemented and covered by the compiler's test suite. Its boundaries are
mostly missing features, plus a handful of constructs the compiler rejects
with a clean error; each links to the chapter that documents it in full.

### The biggest missing feature

* **First-class functions are not implemented yet.** Functions exist only
  at the module top level; a function value cannot be stored in a
  variable, passed, or returned, and calling through a function-typed
  value is rejected
  ([functions](functions.md#functions-are-not-values-yet),
  [type system](types.md#function-types)). This (with closures) is the
  most prominent roadmap item. A consequence: there is **no way to call a
  Lua function from Titan**
  ([Lua interop](lua-interop.md#calling-lua-from-titan)). Writing a
  function *type* in an annotation is itself a clean compile-time error
  ("first-class function types are not supported yet")
  ([type system](types.md#function-types)).

### Smaller gaps and rough edges

* **No `break`, no `goto`, no `for ... in`** — these words are reserved but
  unused; restructure the loop or `return` from it
  ([statements](statements.md#no-break-no-goto)).
* **An option receiver is not auto-unwrapped for a method call:** `p:m()`
  on a `Point?` is a compile-time error — unwrap into a plain record first
  ([records](records.md#records-and-nil),
  [option types](option-types.md#limitations)).
* **There are no explicit option `as` casts:** `e as T` when `e: T?` is a
  compile-time error — unwrap with `or` or a truthiness check instead
  ([option types](option-types.md#limitations)). (Implicit `t1? → t2?`
  conversion does work when `t1` is coercible to `t2`, propagating `nil`.)
* **Two constructs still crash the compiler rather than erroring cleanly:**
  a wrong-arity call to a callee with *multiple* return types (the message
  formatter crashes; [functions](functions.md#strict-arity)) and field
  selection on a call result, `f().x` ([grammar](grammar.md#statements)).
  These are the last known internal-error corners.

### The C FFI

* **The FFI handles functions, scalars, strings and opaque pointers**, and
  is the one place Titan's safety guarantees end — a C function can misuse
  memory and crash the process, and a Titan `string` handed to a C
  function that frees or stores it corrupts the heap. Struct/union fields
  are inaccessible (structs usable only behind opaque pointers), bare
  (non-typedef) enum constants are not imported, and C arrays, function
  pointers, by-value structs and bare `char`/`short`/C `float`/`unsigned`
  have no Titan type — a foreign function using one is simply skipped, so
  referencing it is a clean "not a member" error. Foreign variables are
  read-only, the C namespace is flat with no conflict detection, pointers
  never cross into Lua, and the FFI carries a compile-time POSIX dependency
  ([the full list](ffi.md#summary-of-current-limitations)).

### Other

* **Error handling stops at the first step of its plan.** Titan has no
  raise/catch construct of its own, and `titan.backtrace()` and the merged
  Titan+Lua trace are experimental — Titan frames show mangled C names and
  the two tracebacks sit side by side
  ([error handling](error-handling.md#the-error-handler-and-titanbacktrace)).
* **No standard library yet.** Titan code uses the FFI, imported Titan
  modules, or its Lua host for library functionality.

The [README roadmap](../../README.md) lists where the language is headed;
the [philosophy chapter](philosophy.md) explains the principles that order
that list.
