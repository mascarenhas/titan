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
| [Code generator: overview](codegen-overview.md) | What a generated translation unit looks like; the two-functions-per-function scheme; the Titan native calling convention (including the `_fn` closure parameter); closures, the captured-variable box and bound-method trampolines; the module `_init`/`luaopen_*`/`*_types` protocol; static vs dynamic linking of imports. |
| [Values and the GC](values-and-gc.md) | The C representation of every Titan type; records as CClosure + tagged Udata; the module closure; stack-slot anchoring; `luaC_checkGC` placement; write barriers. First-class function values are boxed `TValue`s — a Titan function value is a `CClosure` with upvalue[0] = the module `_mod`, upvalue[1] = a function-type tag (light userdata, shared across modules through the Lua registry keyed by the canonical type string), upvalue[2] = the native entry pointer (light userdata); each referenceable function has one canonical closure in a dedicated module upvalue slot, so exported functions are referenced by upvalue index with stable identity. |
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

## Known limitations and quirks

Each chapter documents the rough edges of the part it covers — latent
bugs, raw-Lua-error crashes where a clean diagnostic was intended,
`TODO`/`FIXME` gaps, and deliberate-but-surprising boundaries. They are
collected here so a reader knows where the sharp corners are before diving
in; follow the link for the full discussion.

| Where | Limitation / quirk |
| --- | --- |
| [AST and typedecl](ast-typedecl.md#the-cost-of-adding-a-node-or-type) | No compiler-enforced exhaustiveness: a missing visitor/codegen handler for a `_tag` crashes on first contact, not at build time. Some type values (`types.Module`, the FFI `Type.Pointer`/`Typedef`, the `Struct`/`Union` placeholders) [bypass `typedecl`](ast-typedecl.md#typedecllua-constructor-generation) and its arity check (whose error even says "missing" when there are too *many* args). [Decorations](ast-typedecl.md#decorations-who-writes-what-who-reads-it) are unvalidated field assignments (a typo fails only when read) and make post-checker ASTs self-referential (the `TableFormatLevel` print-hang hazard). |
| [Lexer and parser](lexer-parser.md#non-reentrancy) | The parser is **not reentrant** (`THIS_FILENAME`) and runs `grammar:match` unprotected, so an error in a semantic action poisons later parses. Reserved words `break`/`goto`/`in` have [no syntax](lexer-parser.md#one-grammar-no-token-stream). A [missing `syntax_errors` entry](lexer-parser.md#from-label-to-message) shows the user "nil". [Several preserved label quirks](lexer-parser.md#quirks-to-know-about) (`ExpAssign` defined twice, unreachable `AssignImport`). The [location weak-cache](lexer-parser.md#location-tracking) never actually releases entries. |
| [The type checker](checker.md#typescoerceablesource-target--every-implicit-coercion) | `coerceable` clause 1's nil→`void*` tests `.tag` not `._tag` and never fires (nil-to-pointer survives via `compatible`'s nullable-pointer rule). [`ExpExtra`](checker.md#expextra--materializing-multiple-returns): map-initializer extras are silently truncated. [Dead code after an always-returning `if`](checker.md#the-always-returns-analysis) is not analyzed, so a type error there goes unreported. [`as`-cast of an identity type is rejected](checker.md#per-construct-notes-for-contributors); [first-class functions, closures and bound methods are supported](checker.md#per-construct-notes-for-contributors) but foreign (FFI) functions, record types and modules remain non-values; re-declaring a name in the same block silently shadows. [Process-global state](checker.md#process-global-state) must be reset by callers. |
| [Code generator: overview](codegen-overview.md#no-c-ast-templates-utilrender-and-prettylua) | A missing template variable is a hard "Internal compiler error" abort; `reindent_c` is heuristic only. Each release is [pinned to one Lua version](codegen-overview.md#anatomy-of-a-generated-translation-unit) (5.5.0). The [`$LOADMODULES2` re-init branch](codegen-overview.md#prefix_init--idempotent-at-two-levels) is emitted only for more than one dynamic dependency. |
| [Code generator: constructs](codegen-constructs.md#operators-with-inlined-lua-semantics) | Integer `+ - *` and unary `-` are plain C operators with **no overflow handling** and no `-fwrapv` — the suite relies on current gcc/clang wraparound, which C99 does not guarantee. |
| [Values and the GC](values-and-gc.md#gc-discipline-the-invariants) | Under the generational collector a missing barrier or unanchored fresh object is a reliably reproducible use-after-free, not a rare race — the discipline the whole chapter exists to enforce. `types.is_gc` [tests a `Type.Interface` tag](values-and-gc.md#conversion-helpers) for which no constructor exists. |
| [Lua interop internals](lua-interop-internals.md#safety-summary) | Known soft spots, all verified: `boolean` parameters accept anything by truthiness (inconsistent with strict variable/field writes); container contents are not checked at the boundary (aliasing); forged/undersized userdata from C can defeat the tag check. Also: the [reserved error slot is dead groundwork](lua-interop-internals.md#the-lua-entry-wrapper-genluaentry); `checkandset`'s float case emits a [dead second `luaL_error`](lua-interop-internals.md#checkandset-the-tvalue-destination-twin). |
| [FFI internals](ffi-internals.md#platform-constraints-and-failure-modes-summarized) | Compile-time POSIX dependency (`gcc -dM -E`, `cpp -v`); struct/union contents are stubs ([`TODO process fields`](ffi-internals.md#from-c-types-to-titan-types-titan-compilerforeigntypeslua)), bare top-level enum constants register nothing and enum values are not stored, static functions are invisible, [one flat C namespace with no conflict detection](ffi-internals.md#calls-variables-and-the-single-namespace), `#error`/`#pragma`/`#line` ignored. The [C99 grammar is non-reentrant (self-resetting)](ffi-internals.md#the-c99-grammars-c-parserc99lua). A few preprocessor conditions ([`#if` operators](ffi-internals.md#directives-and-conditionals), [unterminated macros](ffi-internals.md#macro-expansion), `NYI long double`) **still escape as raw Lua errors that crash the compiler** rather than diagnostics; an unsupported C type in a signature, by contrast, is now a clean skip (the member is omitted). `typed.lua` ships [disabled](ffi-internals.md#typedlua-the-disabled-run-time-typing-dsl). |
| [Driver and toolchain](driver.md#compiling-one-module-drivercompile) | Commands run through `os.execute` with **no shell escaping**; `driver.compile` [hard-codes `-I titan-runtime`](driver.md#compiling-one-module-drivercompile) ignoring `TITAN_RUNTIME_PATH`; the [compile-time path walk ignores `;;`](driver.md#module-names-and-the-search-paths) (only the run-time loader honors it). [Link-step return values are dropped](driver.md#the-titanc-command-line), so a failed link still exits 0. |

Some of these also surface in the [language reference](../language/index.md)
as user-visible behavior (e.g. integer overflow, container aliasing); the
links above point at the implementation-side discussion of the underlying
cause.

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
