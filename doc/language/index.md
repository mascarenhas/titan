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

Titan is a working prototype, version 0.5. The language documented here
is implemented and covered by the compiler's test suite, with these
notable boundaries:

* **First-class functions are not implemented yet.** Functions exist only
  at the module top level; function *types* appear in the grammar but a
  function value cannot yet be stored in a variable or passed around.
  This (with closures) is the most prominent roadmap item.
* **Floats and `%`:** the modulo operator is not yet implemented for
  float operands (it is for integers). A float `%` passes the
  typechecker and aborts code generation with an internal compiler
  error.
* **The FFI handles functions, scalars, strings and opaque pointers.**
  C structs and unions are parsed but their fields cannot yet be
  accessed from Titan (struct values are usable only behind opaque
  pointers), enum constants are unusable (bare-enum constants are not
  imported; typedef'd-enum constants crash the compiler when used), and
  C arrays have no Titan counterpart.
* **Record limitations:** records cannot yet be declared `local` to a
  module (`local record` is a syntax error; records are always
  exported), and assigning a record constructor expression to a module
  variable inside a function body (`g = { x = 1.0, y = 2.0 }` as a
  statement) passes the typechecker but aborts code generation with an
  internal compiler error — the same crash hits a record-field target
  (`o.f = { ... }`); see the [records chapter](records.md) for the full
  list. A constructor used as the *initializer* of the module
  variable's declaration works; inside a function, assign the result of
  `new` or build the record in a local variable first — both work.
* **No standard library yet.** Titan code uses the FFI, imported Titan
  modules, or its Lua host for library functionality.

The [README roadmap](../../README.md) lists where the language is headed;
the [philosophy chapter](philosophy.md) explains the principles that
order that list.
