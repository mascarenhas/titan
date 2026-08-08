---
name: titan-programmer
description: Write, review, compile, and test statically typed Titan source, especially standard-library modules. Use when editing .titan files, designing Titan APIs or types, working across Lua or C boundaries, or diagnosing Titan syntax and type-checking errors.
---

# Titan programmer

Use this skill for Titan source and standard-library work. Titan is a
**statically typed, ahead-of-time compiled sister language to Lua**, not Lua
source with optional annotations. A `.titan` file goes through `titanc` and C;
do not execute it with `lua` or infer behavior from a Lua manual.

## Read narrowly, from authority

Start with the [quick tour](../../../../doc/quick-tour.md) if the syntax is not
fresh, use the [language index](../../../../doc/language/index.md) as the chapter
catalog, and read the [style guide](../../../../doc/style-guide.md) before
changing standard-library code. The language reference is normative; for any
conversion question, the type chapter's **normative boundary matrix** is the
tie-breaker. Open only the chapters relevant to the change:

| Question | Authoritative chapters |
| --- | --- |
| Static types, conversions, `value`, `as`/`is` | [types](../../../../doc/language/types.md), [options](../../../../doc/language/option-types.md), [Interfaces](../../../../doc/language/interfaces.md) |
| Operators, constructors, declarations, loops | [expressions](../../../../doc/language/expressions.md), [statements](../../../../doc/language/statements.md) |
| Calls, closures, argument/result runs | [functions](../../../../doc/language/functions.md), [named arguments](../../../../doc/language/named-arguments.md), [closures](../../../../doc/language/closures.md), [variadics](../../../../doc/language/variadic-parameters.md), [flexible returns](../../../../doc/language/flexible-returns.md) |
| Data modeling | [arrays/maps](../../../../doc/language/arrays-maps.md), [records](../../../../doc/language/records.md), [unions](../../../../doc/language/unions.md), [aliases](../../../../doc/language/type-aliases.md) |
| Modules, visibility, contributors, artifacts | [modules](../../../../doc/language/modules.md), [source collaboration](../../../../doc/language/source-import-visibility.md), [folder modules](../../../../doc/language/folder-modules.md), [multi-module libraries](../../../../doc/language/multi-module-libraries.md), [static providers](../../../../doc/language/static-compiled-modules.md) |
| Errors and ownership cleanup | [error handling](../../../../doc/language/error-handling.md), [defer](../../../../doc/language/defer.md) |
| Lua and C boundaries | [Lua interop](../../../../doc/language/lua-interop.md), [FFI](../../../../doc/language/ffi.md), [C expressions](../../../../doc/language/c-ffi-expressions.md) |
| Tasks and coroutines | [async I/O](../../../../doc/language/async-io.md), [coroutines](../../../../doc/language/coroutines.md), then the affected standard-library chapter |
| Exact syntax | [grammar](../../../../doc/language/grammar.md) |

For a public standard-library API, also read its
`doc/language/standard-library-<module>.md` chapter (or `async-io.md`) and the
matching implementation documentation. Inspect adjacent `.titan` code and
existing tests before inventing a new pattern.

## Keep the Titan mental model

### Declarations and modules

- Every local variable declaration needs an initializer (except the documented
  zero-initialized C aggregate case). Assignment to an undeclared name is an
  error; Titan has no ambient Lua globals.
- At module top level, `name = expression` is a module-variable declaration,
  not an assignment. No `local` means exported. Its initializer must be a
  permitted constant expression; use the single final root `do ... end` block
  for computed one-time initialization.
- A module-variable declaration sees only earlier imports and earlier module
  variables. Function bodies and nominal/callable declarations are otherwise
  placement-independent. Do not use contributor filename order as a hidden
  dependency mechanism.
- Import Titan modules with `local fs = import "fs"`; `import` is not Lua
  `require`, and a module alias is a prefix rather than a first-class value.
  The canonical short set is `coroutine`, `uv`, `async`, `timer`, `io`, `fs`,
  `net`, `ssl`, `url`, `http`, `os`, `peg`, and `string`. Use qualified imports
  for `titan.math`, `titan.lua`, `titan.iter`, and `titan.gc`.
- A direct source import may select the owner's `local` declarations through
  its alias; that permission is direct-only. Binary imports and Lua remain
  public-only, so do not rely on stale compiled providers for source collaboration.
- A folder module is still one logical module. Its canonical main and immediate
  `.titan` contributors share one namespace, initializer, and artifact;
  top-level `local` is module-private, never file-private. Contributors are not
  importable submodules, and only the main may own the final root initializer.

### Types, absence, and containers

- Titan has no general subtyping. A direct numeric, option, or Interface
  conversion does not automatically lift through Arrays, Maps, functions, or
  nominal fields. An Interface conversion constructs a nominal wrapper; it is
  not inheritance.
- Prefer a precise type over `value`. `value` is a deliberate dynamic boundary,
  not “any Titan expression”: arithmetic, concatenation, length, and indexing
  into it require an explicit checked cast. An implicit typed projection is a
  strict guard; a written `as` can request broader dynamic conversion, and
  `is` is its nonraising predicate twin.
- `integer` and `float` stay distinct. `/` and `^` return `float`; numeric
  `for` bounds must exactly match the control type. Strings are immutable byte
  strings; lengths and standard string indices are byte-oriented.
- `{T}` is an Array with positive integer positions and holes. `{K: V}` is a
  Map. Reads produce `T?`/`V?`; `local x = container[key]` unwraps and raises
  if absent, while `local x? = ...` preserves absence. Writing `nil` deletes,
  and optionizing an element/value type does not create stored nil elements.
- `#array` is the greatest present positive index, not an element count. A
  hole may remain below it. In an unconstrained context `{}` defaults to
  `{integer}`.
- Constructor shape matters: positional fields build an Array; `[key] = value`
  builds a Map; `field = value` is record syntax and needs record context.
  To pass a brace constructor positionally, keep parentheses: `f({x = 1})`.
  Bare `f {x = 1}` is Titan named-argument syntax.
- A condition uses Lua truthiness but does not narrow the operand's static
  type. When the base type can be false, test an option with `x == nil` or
  `x ~= nil` rather than treating truthiness as pure presence.

### Nominal values and calls

- Records are nominal references, not tables. `Rec.new(...)` uses field order;
  `{field = value}` is a context-typed record constructor. Call methods with
  `obj:method(...)`; `obj:method` without arguments is a bound function value.
- Unions are nominal closed alternatives. A variant carries at most one
  payload, and `Union.variant(...)` is positional-only. `case` is not required
  to be exhaustive; unmatched/no-`else` does nothing, so add an `else` when
  fallthrough would be wrong.
- Annotate every named-function parameter. Lambda annotations may be inferred
  only from an expected function type, never from the body.
- A function without a return annotation returns **zero values**, not inferred
  results or one nil. Write `: nil` for one nil, `: (A, B)` for fixed multiple
  results, and the documented flexible-tail syntax only for genuinely
  run-time-variable arity.
- Fixed calls nil-fill omitted parameters, then type-check them. Surplus
  arguments are still evaluated but discarded unless the function is
  variadic. Do not add a variadic tail merely to ignore extras.
- Only the final call in an expression list expands. Parentheses force one
  result. A finite read from a flexible result tail is optional; only an open
  sink preserves the actual run. `_` is an ordinary variable, not discard
  syntax.
- Standalone entry is exactly exported
  `function main(args: {string}): integer`; other `main` signatures make an
  ordinary library module.

### Errors, iteration, and boundaries

- There is no `try`. Attach `catch`/`finally` directly to a block. A catch has
  read-only `error: value` and `traceback: string`; bare `raise` preserves the
  original pair.
- Defer cleanup immediately after successful acquisition. Defers are scoped to
  the current block, run LIFO on fallthrough/return/break/error, and may
  replace the pending result if cleanup raises.
- Generic `for` consumes `(iterator, state, initial_control, close)`, stops only
  when the first iterator result is nil, and runs `close` on every protected
  exit. False is a real iteration value.
- Lua loads application modules with `require "app.mod"` and standard modules
  with qualified names such as `require "titan.fs"`. Titan modules, records,
  unions, Interfaces, and Arrays cross as userdata; Maps cross as Lua tables.
  A plain table can satisfy a Map boundary, never an Array boundary. Container
  crossings are shallow; typed reads guard their contents later.
- Use `foreign import` only after reading both FFI chapters. C types may be
  local implementation types but cannot leak through an exported Titan API.
  Titan operators use Lua-faithful semantics; FFI C-operator mode uses C
  semantics. Titan Arrays are 1-based; C arrays are 0-based.
- Keep raw Lua-stack values, borrowed pointers, native callbacks, and ownership
  machinery behind a narrow typed boundary. For async work, cancellation does
  not end native ownership: retain callback state until terminal completion
  and close resources explicitly.

## Compile and test a small module

Use an installed, ABI-matched Titan toolchain as described by the
[README](../../../../README.md). Run `titanc` from the source-tree root and pass
dotted **module names**, never `.titan` paths.

A minimal two-file scratch tree exercises a library through Titan:

```text
scratch/
  calc.titan
  check.titan
```

```titan
-- calc.titan
function twice(x: integer): integer
  return x * 2
end
```

```titan
-- check.titan
local calc = import "calc"
function main(args: {string}): integer
  if calc.twice(21) == 42 then return 0 else return 1 end
end
```

```sh
(cd scratch && titanc check && ./check)
```

`titanc` resolves `calc` from source, type-checks the whole dependency graph
before code generation, and emits an executable because `check` has exact
`main`. To exercise the Lua boundary instead, omit `main`, run `titanc calc`,
and assert through `lua -e 'assert(require("calc").twice(21) == 42)'` from the
same directory.

For repository changes, follow [AGENTS.md](../../../../AGENTS.md) rather than
guessing installation flags. Standard-library behavior specs belong under
`spec/stdlib/` and run without LuaCov. Rebuild/reinstall through the documented
flow before Busted so `luarocks.loader` does not test a stale installed
snapshot.

## Before finishing

- Recheck exports, constant initialization, option handling, call/result
  shape, and Array-versus-Map intent.
- Audit every Lua/C/async boundary for conversion, rooting, ownership, cleanup,
  and error propagation.
- Add focused behavior tests at the existing layer; do not turn a stdlib API
  test into a compiler-coverage test.
- Update the affected language and implementation documentation when an API or
  user-visible feature changes.
