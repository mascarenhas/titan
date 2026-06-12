# The Titan compiler and runtime

This is the documentation of how Titan is implemented: a prototype
compiler, written in Lua, that translates `.titan` modules into C code
built against the **internals** of the Lua interpreter, plus a small C
runtime-support library. It is written for people who want to change the
compiler. For the language itself, see the
[language reference](../language/index.md).

## The pipeline at a glance

```
source.titan
   │  parser.parse            (lexer.lua + parser.lua, one LPegLabel grammar)
   ▼
AST                            (plain tables, ast.lua / typedecl.lua)
   │  checker.check            (checker.lua + types.lua + symtab.lua)
   ▼
typed & elaborated AST         (decorated with _type/_decl…, coercions made
   │                            explicit as ExpCast, multi-returns as ExpExtra)
   │  coder.generate           (coder.lua — C-source templates)
   ▼
one C translation unit
   │  pretty.reindent_c        (pretty.lua — heuristic reindenter)
   │  driver.compile           (driver.lua — writes .c next to the source,
   ▼                            invokes the system C compiler)
object file ──► driver.compile_library  → module.so   (require-able from Lua)
            └─► driver.compile_program  → executable  (when a main() exists)
```

`titanc` orchestrates the pipeline: it type-checks every requested module
and its imports first, reports *all* type errors and exits before any
code generation, then compiles and links
([driver and toolchain](driver.md)).

Two facts shape everything downstream of the checker:

* **Generated code bypasses the Lua C API.** It includes Lua's internal
  headers (`lobject.h`, `ltable.h`, `lvm.h`, …) and manipulates values,
  tables and the stack directly. That is where Titan's speed comes from,
  and it ties each compiler version to one specific Lua version —
  currently **Lua 5.5.0**, expected as a built source tree in
  `./lua-5.5.0` (see the migration reports below).
* **Titan data is Lua data.** Every Titan value is representable as a
  Lua value, every allocation is a Lua-GC allocation, and the generated
  code maintains the invariants Lua's (now generational) collector
  requires: anchoring fresh objects in stack slots and emitting write
  barriers.

## Reading guide

| Chapter | Covers |
| --- | --- |
| [AST and typedecl](ast-typedecl.md) | The `typedecl` constructor convention, `_tag` string dispatch, the full AST inventory, the decorations the checker adds, and what it costs to add a node or type. |
| [Lexer and parser](lexer-parser.md) | The scannerless LPegLabel grammar: token patterns, the precedence ladder, parse-time desugarings (records → `new`, concat folding), the error-label system, location tracking. |
| [The type checker](checker.md) | Two-pass checking, scopes, the type relations as implemented, and how the checker *rewrites* the AST so the code generator never coerces implicitly. |
| [Code generator: overview](codegen-overview.md) | What a generated translation unit looks like; the two-functions-per-function scheme; the Titan native calling convention; the module `_init`/`luaopen_*`/`*_types` protocol; static vs dynamic linking of imports. |
| [Values and the GC](values-and-gc.md) | The C representation of every Titan type; records as CClosure + tagged Udata; the module closure; stack-slot anchoring; `luaC_checkGC` placement; write barriers. |
| [Code generator: constructs](codegen-constructs.md) | Construct-by-construct translation with generated-C excerpts, including the array/map fast paths and the inlined Lua-semantics arithmetic. |
| [Lua interop internals](lua-interop-internals.md) | The boundary machinery: Lua entry wrappers and per-type checks, record metatables, module-global metatables, record type tags, dynamic module loading, the error handler, the standalone entrypoint, and the safety argument. |
| [FFI internals](ffi-internals.md) | The pure-Lua C toolchain under `foreign import` (preprocessor, C99 grammar, type extraction) and how foreign declarations become Titan types and direct C calls. |
| [Driver and toolchain](driver.md) | `driver.lua`, `titanc`, the runtime support library (`titan-runtime/`), `pretty.lua`, `util.lua`, and every default path and flag. |

## Lua-version migration reports

The cost of building against Lua's internals is paid at Lua upgrades.
These reports document the 5.3 → 5.5 migration and double as a catalogue
of every internal Lua API the generated code touches:

* [Lua 5.3 → 5.5: internal differences that affect Titan](../lua-5.3-to-5.5-internals.md)
* [Titan's migration from Lua 5.3 to Lua 5.5](../lua-5.5-migration.md)

## Repository map

| Path | What it is |
| --- | --- |
| `titanc` | The compiler CLI. |
| `titan-compiler/` | The compiler proper: `lexer`, `parser`, `syntax_errors`, `ast`, `typedecl`, `checker`, `types`, `symtab`, `coder`, `pretty`, `driver`, `foreigntypes`, `location`, `util`. |
| `c-parser/` | The pure-Lua C preprocessor and C99 parser behind `foreign import`. |
| `titan-runtime/` | `titan.h`/`titan.c`, compiled into every module (dynamic loader, error handler); `titanlib.c`, the optional `titan` Lua module (`titan.backtrace()`). |
| `spec/` | The busted test suite; `coder_spec.lua` is end-to-end (generates, compiles and runs C). |
| `examples/`, `testfiles/` | Manual benchmark/demo material (not used by the suite). |
| `doc/` | This documentation, the [language reference](../language/index.md), and the migration reports. |

Development workflow, prerequisites and test commands are in the
repository's [CLAUDE.md](../../CLAUDE.md) and [README](../../README.md);
the short version is: build Lua 5.5.0 in-tree with `-fPIC`, install the
rock (`luarocks make`), and run `busted` from the repository root —
remembering that busted loads the *installed* rock, so re-run
`luarocks make` after editing compiler sources.
