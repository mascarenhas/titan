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
  currently **Lua 5.5.0**. Installed compilers use the matching internal
  source tree staged in the Titan SDK at `<root>/src/lua-5.5.0`; repository checkout mode uses
  `./lua-5.5.0/src` (see the migration reports below).
* **Titan data is Lua data.** Every Titan value is representable as a
  Lua value, every allocation is a Lua-GC allocation, and the generated
  code maintains the invariants Lua's (now generational) collector
  requires: anchoring fresh objects in stack slots and emitting write
  barriers.

## Reading guide

| Chapter | Covers |
| --- | --- |
| [AST and typedecl](ast-typedecl.md) | The `typedecl` constructor convention, `_tag` string dispatch, the full AST inventory, the decorations the checker adds, and what it costs to add a node or type. |
| [Lexer and parser](lexer-parser.md) | The scannerless LPegLabel grammar: token patterns, the precedence ladder, parse-time desugarings (records → `new`, `defer` → `finally`, concat folding), the error-label system, location tracking. |
| [The type checker](checker.md) | Two-pass checking, scopes, the type relations as implemented, and how the checker *rewrites* the AST so the code generator never coerces implicitly. |
| [Type aliases](type-aliases.md) | The dedicated type namespace, lazy transparent resolution, serialized `type_members`, and RTLD_GLOBAL method resolution through a re-exporting DSO. |
| [Code generator: overview](codegen-overview.md) | What a generated translation unit looks like; the two-functions-per-function scheme; the Titan native calling convention (including the `_fn` closure parameter); `codevaluecall`'s exact Titan-closure fast path vs. generic `luaD_callnoyield` path for Lua callables; closures, the captured-variable box and bound-method trampolines; the module `_init`/`luaopen_*`/`*_types` protocol; static vs dynamic linking of imports. |
| [Values and the GC](values-and-gc.md) | The C representation of every Titan type; records as a single tagged Udata; the module Udata `_mod`; stack-slot anchoring; `luaC_checkGC` placement; write barriers. First-class function values are boxed `TValue`s — a Titan function value is a `CClosure` with upvalue[0] = the module `_mod` (itself a Udata, read with `uvalue`), upvalue[1] = a function-type tag (light userdata, shared across modules through the Lua registry keyed by the canonical type string), upvalue[2] = the native entry pointer (light userdata); each referenceable function has one canonical closure in a dedicated module user-value slot, so exported functions are referenced by slot index with stable identity, while non-exact Titan values and other Lua callables use the generic Lua-stack path. |
| [Code generator: constructs](codegen-constructs.md) | Construct-by-construct translation with generated-C excerpts, including the array/map fast paths and the inlined Lua-semantics arithmetic. |
| [Variadic parameters](variadic-parameters.md) | The `...: t` feature end to end: the `: type`/last-only grammar (with untyped-lambda-vararg context inference) and the `ExpDots`/`ExpDotsIndex`/`ExpDotsLen` nodes; the checker's `varargtype` slot, depth-stamped `$vararg` scope rule, and adjust-up vs. whole-tail explist handling; the seven `TitanVarg*` structs, the `_varargs` + `_start` native ABI, the `genluaentry` build and first-class tag dispatch; and the untraced-payload GC discipline. |
| [Error handling](error-handling.md) | Unified Titan/Lua tracebacks via libbacktrace, `#line` source attribution, trace pinning, `raise`/`catch`/`finally` frontend rules, inline Lua longjmp boundaries, pending finally actions, stack relocation, and ABI/search-path notes. |
| [Defer](defer.md) | The parser-only `defer` marker and recursive `simpleblock` lowering into nested `Ast.StatTry` nodes, relying on existing checker/codegen `finally` machinery. |
| [Coroutines](coroutines.md) | The `titan/coroutine.titan` module's Titan-owned transfer policy with a minimal C shim; its qualified `titan.coroutine` identity; the `TValue` FFI boundary; tagged minicoro, suspended matching handlers with stacked inner coroutines, traceback handoff, and coroutine stack sizing. |
| [Libuv continuation runtime](libuv-runtime.md) | The private canonical `uv` provider, public `async` scheduler facade, `timer`/`fs`/`net`/`os` consumers, GC-owned exact native wrappers, the shared-tag continuation pump, direct native callbacks with a Titan trailing catch, filesystem/network/process ownership, cancellation, bootstrap, and deterministic TERM/grace/KILL shutdown. |
| [Libuv DNS and TCP implementation](libuv-networking.md) | The `net` facade, opaque GC-owned address and TCP storage, DNS ownership, stream callbacks, per-Connection FIFO and close state, cancellation, and portable shim boundary. |
| [Lua interop internals](lua-interop-internals.md) | The boundary machinery: Lua entry wrappers and per-type checks, record metatables and metatable-based type identity, the module `Udata`'s member metatable, dynamic module loading, the error handler, the standalone entrypoint, and the safety argument. |
| [FFI internals](ffi-internals.md) | The pure-Lua C toolchain under `foreign import` (preprocessor, C99 grammar, type extraction) and how foreign declarations become Titan types and direct C calls. |
| [Lua C API FFI follow-up](ffi-lua-api-followup.md) | Preliminary notes for a later design pass on calling the Lua C API through the C FFI. This is not part of FFI v1. |
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
| [The type checker](checker.md#typescoerceablesource-target--every-implicit-coercion) | `coerceable` clause 1's nil→`void*` tests `.tag` not `._tag` and never fires (nil-to-pointer survives via `compatible`'s nullable-pointer rule). [`ExpExtra`](checker.md#expextra--materializing-multiple-returns): map-initializer extras are silently truncated. [Dead code after an always-returning `if`](checker.md#the-always-returns-analysis) is not analyzed, so a type error there goes unreported. [First-class functions, closures and bound methods are supported](checker.md#per-construct-notes-for-contributors) but foreign (FFI) functions, record types and modules remain non-values; re-declaring a name in the same block silently shadows. [Process-global state](checker.md#process-global-state) must be reset by callers. |
| [Code generator: overview](codegen-overview.md#no-c-ast-templates-utilrender-and-prettylua) | A missing template variable is a hard "Internal compiler error" abort; `reindent_c` is heuristic only. Each release is [pinned to one Lua version](codegen-overview.md#anatomy-of-a-generated-translation-unit) (5.5.0). The [`$LOADMODULES2` re-init branch](codegen-overview.md#prefix_init--idempotent-at-two-levels) is emitted only for more than one dynamic dependency. |
| [Variadic parameters](variadic-parameters.md#code-generator-the-seven-structs-and-the-native-abi) | `...` is non-first-class (cannot be captured/stored/escape, invisible to inner lambdas) though the declaring function is a normal value; the homogeneous count is capped at `TITAN_VARARG_MAX = 200` (`lu_byte n_args`, an *intentional* cap, runtime-enforced). `...[i]` is typed `t` and **raises** out of range — a deliberate divergence from array `a[i]` (`t?`); `return ...` is fixed-arity adjust-up, not a runtime-sized spread. The backing `Udata0` payload is untraced, so collectable elements must ride upstream Lua-stack anchors. |
| [Code generator: constructs](codegen-constructs.md#operators-with-inlined-lua-semantics) | Numeric operators reproduce Lua 5.5 exactly: integer `+ - *`/unary `-` emit `intop(...)` for defined two's-complement wrap (no signed-overflow UB, `-fwrapv` irrelevant); mixed `integer`/`float` comparisons use the unboxed `titan_*_intfloat`/`titan_eq_intfloat` helpers and compare by mathematical value (**no promotion**). The remaining gap: the general binop fall-through evaluates its two operands in C's unspecified order, not Lua's strict left-to-right (observable only when both operands have side effects). |
| [Values and the GC](values-and-gc.md#gc-discipline-the-invariants) | Under the generational collector a missing barrier or unanchored fresh object is a reliably reproducible use-after-free, not a rare race — the discipline the whole chapter exists to enforce. `types.is_gc` [tests a `Type.Interface` tag](values-and-gc.md#conversion-helpers) for which no constructor exists. |
| [Error handling](error-handling.md) | `finally` deliberately forbids `return` and escaping `break`; a `raise` from cleanup is the sole override path. Error chaining is not modeled: a new error replaces the in-flight value and trace. The inline boundary relies on the vendored Lua 5.5 `lua_longjmp` layout staying in sync with the linked Lua build. |
| [Lua interop internals](lua-interop-internals.md#safety-summary) | Known soft spots, all verified: `boolean` parameters accept anything by truthiness (inconsistent with strict variable/field writes); container contents are not checked at the boundary (aliasing); forged/undersized userdata from C can defeat the tag check. Also: the [reserved error slot is dead groundwork](lua-interop-internals.md#the-lua-entry-wrapper-genluaentry); `checkandset`'s float case emits a [dead second `luaL_error`](lua-interop-internals.md#checkandset-the-tvalue-destination-twin). |
| [FFI internals](ffi-internals.md#platform-constraints-and-failure-modes) | Compile-time POSIX dependency (the configured `CC` probes `/dev/null` for defines and include paths); imported C types are local-only and rejected from serialized module interfaces; bare and typedef'd enum constants import as C integer members with simple numeric values preserved, static functions are imported, function-like macros are invisible, and all imports share [one flat C namespace](ffi-internals.md#calls-and-variables) with no C-symbol namespacing. Owned allocation is intentionally limited (no `void`, incomplete aggregates, C array typedefs, or flexible-array-member structs). The [C99 grammar remains non-reentrant](ffi-internals.md#typelist-extraction). Some preprocessor failures still escape as raw Lua errors rather than diagnostics. `c-parser/typed.lua` ships [disabled](ffi-internals.md#typedlua). |
| [Driver and toolchain](driver.md#module-names-and-the-search-paths) | Compile-time module path walking ignores `;;` expansion (only the ordinary run-time loader expands it). Configurable compiler and flag strings use a deliberately small shell-word parser rather than full shell expansion. |

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
| `titan/` | Titan standard-library sources. They are ordinary qualified `titan.*` modules, built explicitly from source and installed below the matching qualified directory. |
| `titan-runtime/` | `titan.h`/`titan.c` (`RTLD_LAZY` + `RTLD_GLOBAL` generated-import loader and error handler), `titan_coro.c`, and `titan_uv.c`, whose three objects are the exact members of `libtitan.a`; separate vendored `libbacktrace.a`; `titanlib.c`, built separately as `titan.so` (`backtrace`, internal `pin`/`clear`, and the compiler-only `RTLD_LAZY` + `RTLD_LOCAL` interface loader `_loadlib`); `minicoro.h`, `titan_longjmp.h`, and the namespaced `titan/{ffi,coro,uv}.h` SDK headers. |
| `spec/` | The busted test suite; `coder_spec.lua` is end-to-end (generates, compiles and runs C). |
| `examples/`, `testfiles/` | Manual benchmark/demo material (not used by the suite). |
| `doc/` | This documentation, the [language reference](../language/index.md), and the migration reports. |

Development workflow, prerequisites and test commands are in the
repository's [AGENTS.md](../../AGENTS.md) and [README](../../README.md);
the short version is: choose an absolute local `PREFIX`, put its `bin` on
`PATH`, run `make lua`, `make luarocks`, and `make libuv`, then install the
rock with `$PREFIX/bin/luarocks make` and run Busted from the repository root.
`PREFIX` owns Lua/LuaRocks; `ROCKS_TREE` owns the Titan rock, SDK, and stdlib.
The supported workflow currently configures them to the same path, without
making that equality an inherent invariant.
Busted loads the *installed* rock, so re-run that `luarocks make` after editing
compiler sources. Use distinct `/tmp` prefixes for isolated or parallel
verification rather than checkout-local `.lua`/`lua_modules` trees.
