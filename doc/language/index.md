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
implemented and covered by the compiler's test suite, but the prototype
has boundaries — some are missing features, others are constructs that
pass the typechecker yet crash code generation or miscompile. They are
grouped below; each links to the chapter that documents it in full.

### The biggest missing feature

* **First-class functions are not implemented yet.** Functions exist only
  at the module top level; a function value cannot be stored in a
  variable, passed, or returned, and calling through a function-typed
  value is rejected
  ([functions](functions.md#functions-are-not-values-yet),
  [type system](types.md#function-types)). This (with closures) is the
  most prominent roadmap item. A consequence: there is **no way to call a
  Lua function from Titan**
  ([Lua interop](lua-interop.md#calling-lua-from-titan)). Written
  function-type *annotations* are themselves unusable — a zero- or
  two-or-more-parameter type stops the typechecker and a one-parameter
  type aborts code generation
  ([type system](types.md#function-types),
  [grammar](grammar.md#declarations-and-types)).

### Constructs that pass the typechecker but crash code generation

* **Record constructor expressions in some assignment targets.** Assigning
  a constructor (`g = { ... }`, `o.f = { ... }`) to a module variable, a
  record field, or a never-read local *inside a function* aborts code
  generation; `local record` is also a syntax error and records are
  always exported
  ([records](records.md#constructor-expressions),
  [modules](modules.md#initializers-must-be-constant)). Use
  `RecName.new(...)`, a read local, or a multiple assignment. A record
  field that mentions a record declared *later* in the file likewise
  fails to build ([records](records.md#declaring-a-record)).
* **`and` with a plain boolean left operand outside a boolean context**
  (including the ternary `cond and a or b` with a boolean `cond`, and long
  `and` chains) generates invalid C; split into nested `if`s
  ([expressions](expressions.md#and-or-and-not)).
* **A bare `return`** (zero expressions) crashes the compiler instead of
  being accepted or rejected; write `return nil` or omit the statement in
  nil-returning functions
  ([statements](statements.md#return),
  [functions](functions.md#declaring-functions)).
* **Method calls do not unwrap an option receiver:** `p:m()` on a `Point?`
  is a compile-time error — unwrap into a plain record first
  ([records](records.md#records-and-nil),
  [option types](option-types.md#limitations)).
* **Other internal-error corners:** a wrong-arity call to a callee with
  multiple return types ([functions](functions.md#strict-arity)); a
  `repeat`/`until` condition that references a body-local local
  ([statements](statements.md#repeat--until)); and field selection on a
  call result, `f().x` ([grammar](grammar.md#statements)).

### Miscompilations (compile cleanly, wrong at run time)

* **`return f(...) or default`** with an option-returning call as the left
  operand of `or` produces invalid C; route the default through a variable
  ([error handling](error-handling.md#recoverable-failures-without-errors-the-option-idiom)).
* **String comparisons compile to pointer comparisons:** `==` is wrong for
  separately-created equal *long* strings and `<` is not lexicographic at
  all ([expressions](expressions.md#comparisons)).
* **Float→integer conversion checks integrality but not range**, and the
  boundary/container check uses single precision, so an out-of-range or
  sub-float-precision value is silently accepted/truncated
  ([error handling](error-handling.md#float-to-integer-conversion-failures)).
* **Numeric `for` diverges from Lua:** a zero step is not an error, the
  integer counter wraps past the 64-bit limit instead of terminating, and
  the control variable is not read-only
  ([statements](statements.md#the-numeric-for)).

### Missing language features and known gaps

* **No `break`, no `goto`, no `for ... in`** — these words are reserved but
  unused; restructure the loop or `return` from it
  ([statements](statements.md#no-break-no-goto)).
* **The C FFI handles functions, scalars, strings and opaque pointers**,
  but struct/union fields are inaccessible (structs usable only behind
  opaque pointers), bare (non-typedef) enum constants are not imported,
  and there is no mapping for C arrays, function pointers, by-value
  structs, or bare `char`/`short`/C `float`/explicit `unsigned`. Foreign
  variables are effectively read-only, the C namespace is flat with no
  conflict detection, inference from a typedef-returning call crashes,
  pointers never cross into Lua, and the FFI carries no memory safety and
  a compile-time POSIX dependency
  ([the full list](ffi.md#summary-of-current-limitations)).
* **The `?` option-inference marker is silently ignored** on module-level
  variables and on declarations bound to extra multiple-return values;
  annotate with `T?` there
  ([option types](option-types.md#limitations),
  [type system](types.md#type-inference)). Cross-base option conversions
  also force rather than pass `nil` through, and there are no explicit
  option `as` conversions ([option types](option-types.md#limitations)).
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
