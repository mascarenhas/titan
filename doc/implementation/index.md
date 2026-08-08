# The Titan compiler and runtime

This is the documentation of how Titan is implemented: a prototype
compiler, written in Lua, that translates `.titan` modules into C code
built against the **internals** of the Lua interpreter, plus a small C
runtime-support library. It is written for people who want to change the
compiler. For the language itself, see the
[language reference](../language/index.md).

## The pipeline at a glance

```
each flat P.titan or folder P/B.titan + immediate contributors
   │  driver source resolution; parser.parse once per real source file
   │                           (lexer.lua + parser.lua, one LPegLabel grammar)
   ▼
one dense AST per module       (plain tables, ast.lua / typedecl.lua; no
   │                            source-unit wrapper or per-file namespace)
   │  checker.check            (checker.lua + types.lua + symtab.lua)
   ▼
typed & elaborated ASTs        (decorated with _type/_decl… and checker-owned
   │                            adjustment/boundary plans; finite call
   │                            projections as ExpExtra; finite/open demand on
   │                            sinks)
   │  coder.generate           (coder.lua — C-source templates)
   ▼
one C translation unit per logical module
   │  pretty.reindent_c        (pretty.lua — heuristic reindenter)
   │  driver.compile           (driver.lua — writes .c next to the canonical
   │                            flat source or folder main and invokes cc)
   ▼
object files ──► one common-prefix provider.so/provider.a + generated Lua shims
             └─► driver.compile_program → executable (when a main() exists)
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
  currently **Lua 5.5.1**. Installed compilers use the matching internal
  source tree staged in the Titan SDK at `<root>/src/lua-5.5.1`; repository checkout mode uses
  `./lua-5.5.1/src` (see the migration reports below).
* **Titan data is Lua data.** Every Titan value is representable as a
  Lua value, every allocation is a Lua-GC allocation, and the generated
  code maintains the invariants Lua's (now generational) collector
  requires: anchoring fresh objects in stack slots and emitting write
  barriers.

## Reading guide

| Chapter | Covers |
| --- | --- |
| [AST and typedecl](ast-typedecl.md) | The `typedecl` constructor convention, `_tag` string dispatch, the full AST inventory (including written `ExpCast`/`ExpIs`), the decorations the checker adds, and what it costs to add a node or type. |
| [Lexer and parser](lexer-parser.md) | The scannerless LPegLabel grammar: token patterns, the precedence ladder including `as`/`is`, parse-time desugarings (records → `new`, `defer` → `StatTry`/`finallyblock`, concat folding), the error-label system, location tracking. |
| [The type checker](checker.md) | Two-pass checking, scopes, checker-owned assignment/open/boundary plans, shared written cast/type-test validation, and how the checker decorates and rewrites the AST so the code generator never rediscovers a relation. |
| [Source-import collaboration interfaces](source-import-visibility.md) | Trusted source provenance, direct-owner capabilities, compiler-only module views, transitive C context, private module-state layout, and binary isolation. |
| [Type relations and boundary plans](type-relations-and-boundaries.md) | The normative split among gradual consistency, direct coercion, callable/assignment adjustment, strict guards, written and dynamic coercion, comparison, guardability, checker annotations, and the strict-Titan versus genuine-Lua boundary matrix. |
| [Interfaces](interfaces.md) | Interface declarations and metadata, direct structural satisfaction without subtyping, frozen conversion/adapter plans, nominal wrapper layout, exact and adjusted dispatch, bound methods, dynamic checks, separate compilation, and the ABI-0.20 contract. |
| [Named arguments](named-arguments.md) | The temporary `ArgsNamed*` nodes, declaration-only `paramnames` metadata, C prototype-name preservation, checker normalization, source-order lowering, record omission, and the 0.13 interface ABI. |
| [Type aliases](type-aliases.md) | The dedicated type namespace, lazy transparent resolution, serialized `type_members`, and original-owner static/method resolution through DSO and archive re-exports. |
| [Union implementation](unions.md) | Union AST and constructor synthesis, declaration staging, variant metadata, payload eligibility, optional case coverage and closed-union control-flow proof, full-block lowering, userdata layout, Lua exposure, and the union schema introduced in ABI 0.19. |
| [Code generator: overview](codegen-overview.md) | What a generated translation unit looks like; native, strict Titan-generic, and coercive genuine-Lua function entries; the native calling convention (including `_fn`); exact branded, non-exact branded, and non-Titan `codevaluecall` branches; closure branding, captures and bound-method trampolines; the module `_init`/`luaopen_*`/`*_types` protocol; static vs dynamic linking of imports. |
| [Values and the GC](values-and-gc.md) | The C representation of every Titan type; records as a single tagged Udata; the module Udata `_mod`; stack-slot anchoring; `luaC_checkGC` placement; write barriers. First-class function values are boxed `TValue`s: a canonical Titan `CClosure` keeps `_mod`, its exact tag, and its native pointer in upvalues 0–2, stores the opaque Titan-function brand in upvalue 3, preserves captures/receiver from slot 4, and stores the strict Titan-generic light C function in its final upvalue. |
| [Dense Arrays](dense-arrays.md) | ABI-0.17 backing/length internals plus the ABI-0.20 boundary update: one shared proxy metatable, backing key 0, proxy user values for backing and the construction-selected Lua writer, stock GC/barriers, strict typed reads, dynamic Lua writes, module-local writer generation, internal/boxed representations, and generated operations. |
| [Code generator: constructs](codegen-constructs.md) | Construct-by-construct translation with generated-C excerpts, including cast/type-test predicates, array/map fast paths, and the inlined Lua-semantics arithmetic. |
| [Variadic parameters](variadic-parameters.md) | The `...: t` feature end to end: the `: type`/last-only grammar (with untyped-lambda-vararg context inference) and the `ExpDots`/`ExpDotsIndex`/`ExpDotsLen` nodes; the checker's `varargtype` slot, depth-stamped `$vararg` scope rule, and shared finite/open demand; the seven `TitanVarg*` structs used for both input and output runs, the `_varargs` + `_start` native ABI, the `genluaentry` build and first-class tag dispatch; and the untraced-payload GC discipline. |
| [Flexible returns and contextual `value` calls](flexible-returns.md) | The separate `flexrettype` shape, finite/open result-demand elaboration, contextual callable synthesis, directional callable adjustment, checker-owned open plans, caller-owned output descriptors, three-way function-value dispatch, wrapper result requests, GC/finally discipline, and ABI 0.14 origins. |
| [Error handling](error-handling.md) | Unified Titan/Lua tracebacks via libbacktrace, `#line` source attribution, trace pinning, `raise`/`catch` frontend rules, inline Lua longjmp boundaries, pending finally actions, stack relocation, and ABI/search-path notes. |
| [Defer](defer.md) | The parser-only `defer` marker and recursive `simpleblock` lowering into nested `Ast.StatTry` nodes with `finallyblock`, relying on existing checker/codegen `finally` machinery. |
| [Coroutines](coroutines.md) | The `titan/coroutine.titan` module's Titan-owned transfer policy with a minimal C shim; its qualified `titan.coroutine` identity; the `TValue` FFI boundary; tagged minicoro, suspended matching handlers with stacked inner coroutines, traceback handoff, and coroutine stack sizing. |
| [I/O-library implementation](io-library.md) | String-writer-based one-write printing, the ReaderCloser itself as iterator state, literal line reads and idempotent loop cleanup, plus shell-process facade ownership, cached wait status, and retryable close/reaping. |
| [Libuv continuation runtime](libuv-runtime.md) | The private logical `uv` owner inside the combined standard provider, public `async` facade, structured Task outcomes, closeable bounded circular-buffer channels and string Reader/Writer adapters, terminal-listener combinators and explicit suspension, one shared coroutine tag with direct `Call` dispatch, exact callbacks, cancellation, bootstrap, and final `uv_walk` cleanup. |
| [Extending the libuv binding](libuv-extension-guide.md) | Source-grounded recipes for adding synchronous calls, one-shot callbacks, persistent multi-shot sources, and handle types without rebuilding scheduler machinery, plus the reproducible libuv 1.52.1 API-coverage snapshot. |
| [LPegLabel embedding and `titan.peg`](lpeglabel-embedding.md) | The pinned private engine, symbol and registry namespace, five-member source archive, typed pattern/capture boundary, absolute failure adapter, per-state roots and weak relabel caches, and metadata-free payload in the seventeen-root provider. |
| [String-library implementation](string-library.md) | Exact-byte storage, Lua 5.5 format/pack translation through C99 FFI, synchronous in-memory builders, regex parsing/continuation compilation over `titan.peg`, dense capture state, and raw-Lua stack/root discipline. |
| [Mathematical-library implementation](math-library.md) | Fixed typed numeric signatures over C99 FFI, the Titan xoshiro256** port and unbiased projection, and length-bounded Lua-numeral parsing without Lua API calls. |
| [Lua-loading library implementation](lua-library.md) | The `luaL_loadbufferx` stack ledger, Reader/File ownership, asynchronous `package.path` search, cache and concurrent-load state, mutable-searcher policy, and GC roots. |
| [Iteration-library implementation](iter-library.md) | The trusted `lua_next` stack ledger, traced key/value transfer, generic-for tuple shape, and pure Array iteration through inner nil elements. |
| [Garbage-collection library implementation](gc-library.md) | Preserving existing metatables while setting weak modes or finalizer ownership, raw-stack cleanup and finalizer marking, and stack-neutral Lua 5.5 collector control and parameter calls. |
| [Libuv DNS and TCP implementation](libuv-networking.md) | The `net` facade, opaque GC-owned address and TCP storage, exact DNS and stream callbacks, one-waiter multi-shot buffering, libuv-ordered writes, cancellation, close state, and the portable shim boundary. |
| [TLS-library implementation](ssl-library.md) | High-level composition over `net.Connection`, OpenSSL memory-BIO ownership, verified DNS/IP identities, serialized WANT-read/write state-machine progress, clean-versus-truncated EOF, and bundled/system provider payload. |
| [URL-library implementation](url-library.md) | One-time absolute and request-boundary Relabel PEGs, structured failure tuples, string-based byte normalization, and the reusable high-level boundary consumed by HTTP. |
| [HTTP-library implementation](http-library.md) | The high-level net/SSL/URL folder module, exact synchronous llhttp callback trampolines with a GC-owned Titan `{Event}` Array, streaming framing, concrete-listener conversion boundary, and ownership-aware absolute request-header idle deadlines composed from public async Tasks. |
| [Lua interop internals](lua-interop-internals.md) | The boundary machinery: coercive genuine-Lua and strict Titan-generic stack entries, shared target-directed dynamic plans, record/module/Array writes, function branding and result policy, nominal metatables, dynamic loading, the error handler, the standalone entrypoint, and the safety argument. |
| [FFI internals](ffi-internals.md) | The pure-Lua C toolchain under `foreign import` (preprocessor, C99 grammar, type extraction) and how foreign declarations become Titan types and direct C calls. |
| [C FFI declarations and expressions](c-ffi-expressions.md) | File/prototype tag identity, exact declarators, target arithmetic profiles, session-scoped C probes, contextual pointer conversions, automatic aggregate spills, typed object-macro values, lazy macro-field projection, preprocessing, and C operator traits. |
| [Trusted Lua C API FFI boundary](ffi-lua-api-followup.md) | The general public-FFI exclusion, the audited standard-library exception, its current operation allowlist and stack-effect ledger, and the remaining design work before arbitrary Titan code can use the Lua C API. |
| [Driver and toolchain](driver.md) | `driver.lua`, `titanc`, the runtime support library (`titan-runtime/`), `pretty.lua`, `util.lua`, and every default path and flag. |
| [Folder modules](folder-modules.md) | Tagged flat/folder source resolution, independent parsing into one dense AST, shared checking/codegen identity, deterministic ordering, artifacts, and the `titan.uv` source ensemble. |
| [Multi-module libraries](multi-module-libraries.md) | Prefix-container discovery, strict DSO ABI/types membership claims, transient `Type.Module.file`, one-object-per-module linking, generated Lua shims, the lazy/global support helper, and paired standard-library publication. |
| [Static compiled modules](static-compiled-modules.md) | Canonical object-section metadata, bounded ar/ELF/Mach-O/fat parsing, static-provider resolution and native provenance, deterministic archive flattening, three-way protocol validation, and paired publication. |

## Lua-version migration reports

The cost of building against Lua's internals is paid at Lua upgrades.
These reports document the 5.3 → 5.5 migration and the 5.5.1 point-release
audit. They double as a catalogue of every internal Lua API the generated code
touches:

* [Lua 5.3 → 5.5: internal differences that affect Titan](../lua-5.3-to-5.5-internals.md)
* [Titan's migration from Lua 5.3 to Lua 5.5](../lua-5.5-migration.md)
* [Lua 5.5.0 → 5.5.1: exhaustive update audit](lua-5.5.1-update.md)

## Known limitations and quirks

Each chapter documents the rough edges of the part it covers — latent
bugs, raw-Lua-error crashes where a clean diagnostic was intended,
`TODO`/`FIXME` gaps, and deliberate-but-surprising boundaries. They are
collected here so a reader knows where the sharp corners are before diving
in; follow the link for the full discussion.

| Where | Limitation / quirk |
| --- | --- |
| [AST and typedecl](ast-typedecl.md#the-cost-of-adding-a-node-or-type) | No compiler-enforced exhaustiveness: a missing visitor/codegen handler for a `_tag` crashes on first contact, not at build time. Some type values (`types.Module`, the FFI `Type.Pointer`/`Typedef`, the `Struct`/`Union` placeholders) [bypass `typedecl`](ast-typedecl.md#typedecllua-constructor-generation) and its arity check (whose error even says "missing" when there are too *many* args). [Decorations](ast-typedecl.md#decorations-who-writes-what-who-reads-it) are unvalidated field assignments (a typo fails only when read) and make post-checker ASTs self-referential (the `TableFormatLevel` print-hang hazard). |
| [Lexer and parser](lexer-parser.md#non-reentrancy) | The parser is **not reentrant** (`THIS_FILENAME`) and runs `grammar:match` unprotected, so an error in a semantic action poisons later parses. `break` and generic `for ... in` are real syntax; reserved `goto`/`::` remain [recognized but unused](lexer-parser.md#one-grammar-no-token-stream). A [missing `syntax_errors` entry](lexer-parser.md#from-label-to-message) shows the user "nil". [Several preserved label quirks](lexer-parser.md#quirks-to-know-about) (`ExpAssign` defined twice, unreachable `AssignImport`). The [location weak-cache](lexer-parser.md#location-tracking) never actually releases entries. |
| [The type checker](checker.md#the-relations-and-plans-in-typeslua) | Computed Map keys/values, record fields, named arguments, and parenthesized expressions are deliberately finite scalar consumers; they never become open-result sinks. [Dead code after a proven non-fallthrough statement](checker.md#non-fallthrough-analysis) is not analyzed, so a type error there goes unreported. [First-class functions, closures and bound methods are supported](checker.md#per-construct-notes-for-contributors) but foreign (FFI) functions, record types and modules remain non-values; re-declaring a name in the same block silently shadows. [Process-global state](checker.md#process-global-state) must be reset by callers. |
| [Union implementation](unions.md#case-checking-and-control-flow) | Case coverage is optional, but complete coverage of the statically known closed union proves non-fallthrough when every arm terminates; imported hidden variants remain in `nvariants`, so visible arms alone cannot falsely establish that proof. `Type.Variant` is validated union-owned interface metadata, never a source or value-facing type. |
| [Code generator: overview](codegen-overview.md#no-c-ast-templates-utilrender-and-prettylua) | A missing template variable is a hard "Internal compiler error" abort; `reindent_c` is heuristic only. Each release is [pinned to one Lua version](codegen-overview.md#anatomy-of-a-generated-translation-unit) (5.5.1). The [`$LOADMODULES2` re-init branch](codegen-overview.md#prefix_init-idempotent-at-two-levels) is emitted only for more than one dynamic dependency. |
| [Variadic parameters](variadic-parameters.md#code-generator-the-seven-structs-and-the-native-abi) | `...` is non-first-class (cannot be captured/stored/escape, invisible to inner lambdas) though the declaring function is a normal value; the homogeneous count is capped at `TITAN_VARARG_MAX = 200` (`lu_byte n_args`, an *intentional* cap, runtime-enforced). `...[i]` is typed `t` and **raises** out of range — a deliberate divergence from array `a[i]` (`t?`). `return ...` is finite projection in a fixed-result function, but it preserves a runtime-sized remainder when the enclosing function declares a flexible output tail. Descriptor payloads are untraced, so collectable elements need independent Lua-stack roots. |
| [Code generator: constructs](codegen-constructs.md#operators-with-inlined-lua-semantics) | Numeric operators reproduce Lua 5.5 exactly: integer `+ - *`/unary `-` emit `intop(...)` for defined two's-complement wrap (no signed-overflow UB, `-fwrapv` irrelevant); mixed `integer`/`float` comparisons use the unboxed `titan_*_intfloat`/`titan_eq_intfloat` helpers and compare by mathematical value (**no promotion**). The remaining gap: the general binop fall-through evaluates its two operands in C's unspecified order, not Lua's strict left-to-right (observable only when both operands have side effects). |
| [Values and the GC](values-and-gc.md#gc-discipline-the-invariants) | Under the generational collector a missing barrier or unanchored fresh object is a reliably reproducible use-after-free, not a rare race — the discipline the whole chapter exists to enforce. Private Array writer user values and function-entry trailers add traced edges that must follow the same rooting/barrier rules. |
| [Error handling](error-handling.md) | `finally` deliberately forbids `return` and escaping `break`; a `raise` from cleanup is the sole override path. Error chaining is not modeled: a new error replaces the in-flight value and trace. The inline boundary relies on the vendored Lua 5.5 `lua_longjmp` layout staying in sync with the linked Lua build. |
| [Lua interop internals](lua-interop-internals.md#safety-summary) | Dynamic conversion is intentionally broader at written/genuine-Lua boundaries than at strict Titan observations; raw Maps still cannot intercept Lua writes, so later typed reads are the enforcement point. Privileged C/debug code can forge or corrupt private userdata/upvalue invariants. The [reserved error slot remains dead groundwork](lua-interop-internals.md#the-two-lua-stack-entries-genluaentry). |
| [FFI internals](ffi-internals.md#platform-constraints-and-failure-modes) | Compile-time POSIX dependency (the configured `CC` probes `/dev/null` for defines and include paths); imported C types are local-only and rejected from serialized module interfaces; bare and typedef'd enum constants import as C integer members with simple numeric values preserved, static functions are imported, function-like macros are invisible, and all imports share [one flat C namespace](ffi-internals.md#calls-and-variables) with no C-symbol namespacing. Owned allocation is intentionally limited (no `void`, incomplete aggregates, C array typedefs, or flexible-array-member structs). The [C99 grammar remains non-reentrant](ffi-internals.md#typelist-extraction). Some preprocessor failures still escape as raw Lua errors rather than diagnostics. `c-parser/typed.lua` ships [disabled](ffi-internals.md#typedlua). |
| [Driver and toolchain](driver.md#module-names-and-the-search-paths) | Compile-time and run-time Titan paths share `;;` default insertion, but generated Lua shims intentionally use the independent `package.cpath` template order. Configurable compiler and flag strings use a deliberately small shell-word parser rather than full shell expansion. |

Some of these also surface in the [language reference](../language/index.md)
as user-visible behavior (e.g. integer overflow, container aliasing); the
links above point at the implementation-side discussion of the underlying
cause.

## Repository map

| Path | What it is |
| --- | --- |
| `titanc` | The compiler CLI. |
| `titan-compiler/` | The compiler proper: `lexer`, `parser`, `syntax_errors`, `ast`, `typedecl`, `checker`, `types`, `symtab`, `coder`, `pretty`, `driver`, `staticmetadata`, `foreigntypes`, the C-FFI `cdeclarator`/`cpreamble`/`csemantics`/`cprobe` modules, `location`, and `util`. |
| `c-parser/` | The pure-Lua C preprocessor and C99 parser behind `foreign import`. |
| `titan/` | Titan standard-library sources. They are seventeen independent qualified `titan.*` modules linked together into the physical `titan.so` and `titan.a`; `titan.io` owns the standard Interface vocabulary and I/O helpers, `titan.url` owns reusable URL parsing, and `titan.uv`, `titan.http`, `titan.peg`, and `titan.string` dogfood folder ensembles. The generated `titan/*.lua` files are logical-module shims, not sources. |
| `titan-runtime/` | `titan.h`/`titan.c` (`RTLD_LAZY` + `RTLD_GLOBAL` generated-import loader and error handler), `titan_coro.c`, and `titan_uv.c`, whose three objects are the exact members of runtime-SDK `libtitan.a`; separate vendored `libbacktrace.a`; `titanlib.c`, carried as `titanlib.o` into the full standard `titan.so`/`titan.a` pair and linked alone into the private bootstrap, exposing `backtrace`, internal `pin`/`clear`, compiler-local `_loadlib`, and shim-facing `_loadlibglobal`; `minicoro.h`, `titan_longjmp.h`, and the namespaced `titan/{ffi,coro,uv}.h` SDK headers. |
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
