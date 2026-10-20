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
   │  checker.check            (checker.lua facade + checker/* slices,
   │                            types.lua + symtab.lua)
   ▼
typed & elaborated ASTs        (decorated with _type/_decl… and checker-owned
   │                            adjustment/boundary plans; finite call
   │                            projections as ExpExtra; finite/open demand on
   │                            sinks)
   │  driver header planning   (all optional source-foreign `*.titan.h`
   │                            companions are prepared before any object)
   │  coder.generate           (coder.lua facade + coder/* template slices)
   ▼
one C translation unit per logical module
   │  clang-format             (opt-in --pretty-print; fixed explicit style)
   │  #line normalization      (ordinary mode; coverage uses final lexical
   │                            marker conversion instead)
   │  driver.compile           (driver.lua — writes .c at the canonical output
   │                            path, then invokes cc)
   ▼
object files ──► one common-prefix provider.so/provider.a + generated Lua shims
             └─► driver.compile_program → executable (when a main() exists)
```

`titanc` orchestrates the pipeline: by default it checks selected source
modules before any code generation, reports all errors, then compiles and
links. `--incremental` can reuse source-object declarations and code, while
`-c` stops at object/header generation
([driver and toolchain](driver.md)).

Two facts shape everything downstream of the checker:

* **Generated code bypasses the Lua C API.** It includes Lua's internal
  headers (`lobject.h`, `ltable.h`, `lvm.h`, …) and manipulates values,
  tables and the stack directly. That is where Titan's speed comes from,
  and it ties each compiler version to one specific Lua version —
  currently **Lua 5.5.1**. Installed compilers use the matching internal
  source tree staged in the Titan SDK at `<root>/src/lua-5.5.1`; repository checkout mode uses
  `./lua-5.5.1/src` (see [Lua installation](driver.md#lua-installation-and-executable-relative-search-paths)).
* **Titan data is Lua data.** Every ordinary Titan value is representable as
  a Lua value, and generated GC allocations obey Lua's (now generational)
  collector invariants: fresh objects are anchored in stack slots and writes
  receive the required barriers. Direct C FFI locals are the deliberate
  exception: exact native scalars and eligible fixed aggregates can live in
  nominal payloads, with checked boxing only at a real dynamic boundary. A
  target-directed `.new`/`.new_array` plan can also select automatic storage or
  storage inside the final nominal owner.

## Reading guide

| Chapter | Covers |
| --- | --- |
| [Repository development workflow](repository-workflow.md) | Isolated prefix/submodule setup, profile and command selection, installed versus checkout compiler tests, shared-output ownership, and fixture cleanup. |
| [Continuous integration and platform validation](continuous-integration.md) | Linux producer/consumer lanes, concurrency and sharding, packaging/coverage ordering, cache ownership, sanitizer diagnostics, and the local/manual macOS pre-merge gate. |
| [Standard-library implementation rules](standard-library-maintenance.md) | Declaration/body ownership, meaningful adapters and cached invariants, counted FFI storage, precise callback/result APIs, narrow Lua/C boundaries, and public behavior test placement. |
| [Documentation comments](documentation-comments.md) | LDoc-style summaries and tags retained for editor hover and completion. |
| [AST and typedecl](ast-typedecl.md) | Adding or changing AST nodes and types; `typedecl` constructors, `_tag` dispatch, pass-owned decorations, handwritten visitor coverage, and subset assertions. |
| [Lexer and parser](lexer-parser.md) | Parsing syntax and reporting locations/errors; scannerless LPegLabel grammar, bounded lookahead, committed alternatives, fold captures, precedence, desugaring, and transactional parser state. |
| [The type checker](checker.md) | Resolving declarations/scopes and producing a typed, elaborated AST; staged checking, implicit conversions, call/list adjustment, finite/open demand, and non-fallthrough analysis. |
| [Const-value implementation](const-values.md) | Enforcing const bindings, fields, and Arrays; initialization authority, Interface snapshots, copy/freeze and linear-use analysis, mutable/const proxy behavior, and compiled descriptors. |
| [Explicit source-import collaboration interfaces](source-import-visibility.md) | Accessing module-private declarations through explicit `.titan` imports; source-required resolution, trusted provenance, generated-header collaboration, private module state, and binary isolation. |
| [Type relations and boundary plans](type-relations-and-boundaries.md) | Deciding which assignments, casts, calls, and comparisons are valid; consistency versus coercion, strict guards, dynamic conversion, callable adjustment, and checker-owned boundary plans. |
| [Generics](generics.md) | Checking generic applications before erasure; local inference, rigid binders, constraints, frozen declaration schemes, ordinary cast/adapter insertion, compiled interfaces, and one implementation per declaration. |
| [Closure adjustment wrappers](closure-adjustment-wrappers.md) | Converting first-class functions to another callable signature; frozen `CallablePlan`, missing-result nil fill, target-tagged adapter closures, native/Lua/strict entries, and rooting. |
| [Interfaces](interfaces.md) | Converting records/unions to Interfaces and dispatching their members; structural satisfaction without subtyping, field snapshots, frozen adapters, bound methods, dynamic witnesses, and separate compilation. |
| [Named arguments](named-arguments.md) | Matching named call labels while preserving evaluation order; temporary `ArgsNamed*` nodes, declaration-only `paramnames`, C prototype names, positional normalization, and record omission. |
| [Record constructors](record-constructors.md) | Calling record namespaces and overriding `new`; parser desugaring, raw-literal construction authority, generic/compiled declarations, default-only allocation, and Lua namespace calls. |
| [Type aliases](type-aliases.md) | Resolving transparent compile-time type names; separate type namespace, lazy resolution, serialized `type_members`, and original-owner nominal member lookup across providers. |
| [Union implementation](unions.md) | Constructing tagged variants and checking `case` dispatch; payload eligibility, visibility frontiers, positional/named projections, closed-union non-fallthrough proof, userdata layout, and serialized schemas. |
| [Code generator: overview](codegen-overview.md) | Organizing generated C and callable/module protocols; native, strict Titan-generic, and coercive Lua entries, function branding/captures, cross-state closure manifests and typed capture reconstruction, bound methods, initialization, native provider descriptors, and dependency wiring. |
| [Values and the GC](values-and-gc.md) | Keeping generated values alive under Lua GC; C representations, semantic/allocation/result roots, stack rebasing, collection points, and owner-specific write barriers. |
| [Native nominal storage](nominal-storage.md) | Laying out record/union fields in traced uservalues and native C payloads; public prefixes/private layout, embedded aggregates, exact native options, fresh construction, and callback access. |
| [Dense Arrays](dense-arrays.md) | Implementing Array indexing, length, mutation, and Lua exposure; backing/proxy identity, explicit `lenhint`, mutable writers, const copy/freeze, strict reads, and resizing. |
| [Code generator: constructs](codegen-constructs.md) | Lowering expressions and statements to C; assignment/control flow, container access, casts/tests, Map metamethod paths, equality, and arithmetic matching Lua semantics. |
| [Immediately called anonymous functions](immediate-functions.md) | Inlining immediately invoked anonymous functions without allocating closures; literal eligibility, logical function boundaries, return demand, captures, conversions, and protected cleanup. |
| [Variadic parameters](variadic-parameters.md) | Implementing homogeneous variadic inputs `...: t`; count/index/spread expressions, lambda inference, noncapturable scope, `TitanVarg*` descriptors, and native/Lua call transport. |
| [Flexible returns and contextual `value` calls](flexible-returns.md) | Implementing runtime-sized return tails and contextual calls through `value`; declared versus consumed shape, finite/open demand, callable adjustment, output descriptors, and pending-return lifetimes. |
| [Spread expressions](spread-expressions.md) | Expanding Arrays, integer-Maps, and varargs into expression lists; shared `ExpSpread` carriers/projections, ranges, non-contiguous reads, sink-capacity checks, and element ownership. |
| [Error handling](error-handling.md) | Unified Titan/Lua tracebacks via libbacktrace, `#line` source attribution, trace pinning, `raise`/`catch` frontend rules, inline Lua longjmp boundaries, pending finally actions, stack relocation, and ABI/search-path notes. |
| [Defer](defer.md) | The parser-only `defer` marker and iterative statement-list lowering into nested `Ast.StatTry` nodes with `finallyblock`, relying on existing checker/codegen `finally` machinery. |
| [Coroutines](coroutines.md) | Transferring values/errors across stackful resume/yield and tagged nested coroutines; Titan policy, source-defined minicoro entry, `TValue` rooting, current lookup, traceback handoff, and stack sizing. |
| [I/O-library implementation](io-library.md) | String-writer-based one-write printing, the ReaderCloser itself as iterator state, literal line reads and idempotent loop cleanup, plus shell-process facade ownership, cached wait status, and retryable close/reaping. |
| [Operating-system library implementation](os-library.md) | Owning process and host policy above UV/async; spawn transactions, parent stdio, buffered capture, exit/signal subscriptions, calendars/environment, cancellation, and graceful exit. |
| [Lexical filesystem paths](standard-library-path.md) | Parsing and normalizing lexical filesystem paths without I/O or physical canonicalization; matching Titan/Lua grammars, Windows volumes/namespaces, target selection, and portable cases. |
| [Filesystem-library implementation](filesystem-library.md) | Owning high-level Files and Watchers above UV/async; descriptor lifetime, one-shot requests, missing-only metadata, watcher buffering/classification, stop/drain behavior, and asynchronous close. |
| [Async runtime and public libuv ownership](libuv-runtime.md) | Task scheduling over public UV, preaccepted native retirement cells and durable receipt, binding/rollback, optional exact-owner cleanup/final epoch, pending terminal publication, logical close and explicit driver retry, ready recovery, ordinary Completion/external waits, subscriptions/combinators/listeners, eager coalescing receivers and native slot commits, workers, bootstrap and shutdown. |
| [Async and I/O allocation results](async-allocation-results.md) | Matched allocation measurements, Completion representation costs, generated-C evidence, collection behavior, TCP scratch retention, and the reproducible benchmark. |
| [Extending the libuv binding](libuv-extension-guide.md) | Adding public `uv_*` bindings and ordinary Task adapters; operation classification, native owners, callback frames, request retirement, subscriptions, workers, and API-coverage validation. |
| [LPegLabel embedding and `titan.peg`](lpeglabel-embedding.md) | Implementing typed PEG/Relabel matching over private LPegLabel; engine namespacing, pattern/capture and exact string-label boundaries, failure positions, per-state roots, weak caches, and provider payload. |
| [String-library implementation](string-library.md) | Exact-byte storage, Lua 5.5 format/pack translation through C99 FFI, synchronous in-memory builders, regex parsing/continuation compilation over `titan.peg`, dense capture state, and raw-Lua stack/root discipline. |
| [Mathematical-library implementation](math-library.md) | Fixed typed numeric signatures over C99 FFI, the Titan xoshiro256** port and unbiased projection, and length-bounded Lua-numeral parsing without Lua API calls. |
| [Lua-state and loading library implementation](lua-library.md) | Independent-state ownership, native loader/provider snapshots, protected execution and stack reset, canonical transfer copy/borrow policies through separate Lua carriers, custom payload bytes and borrowed pointers, worker packets/cancellation, Receiver bootstrap/teardown; current-state loading, Reader/File ownership, and cooperative require. |
| [Thread-library implementation](thread-library.md) | Mutex-guarded rings and waiter queues, payload-independent iteration, shared external-wake suspension with $O(1)$ cancellation unlink, packet-scoped endpoints, C-only release/drain chains and last-`Receiver` pin, joinable OS-thread tokens, OS-join-gated `Thread:join()`, a prearmed native-retirement proxy for `Thread:task()`, direct-payload cancellation kind metadata, joinable-token abandonment, isolated worker states, and Group membership with memoized proxy monitors and explicit driver/constructor setup retries. |
| [Iteration-library implementation](iteration-library.md) | The trusted `lua_next` stack ledger, traced key/value transfer, generic-for tuple shape, and pure Array iteration through inner nil elements. |
| [Garbage-collection library implementation](gc-library.md) | Preserving existing metatables while setting weak modes or finalizer ownership, raw-stack cleanup and finalizer marking, and stack-neutral Lua 5.5 collector control and parameter calls. |
| [Reflection-library implementation](standard-library-reflect.md) | Branded runtime metadata, independent descriptor hydration and generic erasure, generated field accessors and native projections, default construction with traced ownership, and explicit nominal/C declaration resolution. |
| [JSON-library implementation](json-library.md) | Parsing, encoding, and mapping JSON to typed records/unions; Relabel folds, exact locations/numbers, reflected constructors, null policy, UTF-8 escaping, cycles, and resource budgets. |
| [Protocol Buffers-library implementation](protobuf-library.md) | Public graph traversal, anonymous field descriptors, typed inspected-root collaboration, reflected native projections/construction, compiler-generated nominal codecs sharing root state with the reflective codec through one checked handoff entry, wire parsing, schemas, and state-transfer integration. |
| [Transfer-policy implementation](transfer-library.md) | Canonical policy and native packet ownership below async, direct scalar/closure classification, single-root structural encoding, consuming raw-slot decode with one native catch and the caller-guard write rule, execution-local exact-top scopes with fresh-frame finalization and bounded state-local reuse, aligned trailing packet attachments and abandonment guards, C-only disposal/provider lifetime, stateful loading, and manual resource contracts. |
| [SQLite-library implementation](sqlite3-library.md) | Executing SQLite work without entering Titan from workers; C-only packets, Connection/Statement/Cursor reservations, cancellation-insensitive retirement, owned row decoding, and reflection mapping. |
| [DNS and TCP implementation](libuv-networking.md) | Owning DNS/TCP socket policy above UV/async; copied addresses, connection admission, optional TCP reuse-port binds, buffered reads/accepts, pending-input snapshots and observers, ordered writes, cancellation, and connection/request retirement. Opt-in demand-driven reads support Windows connection handoff after callback retirement. |
| [TLS-library implementation](ssl-library.md) | High-level composition over `net.Connection`, OpenSSL memory-BIO ownership, TCP reuse-port forwarding, verified DNS/IP identities, serialized WANT-read/write state-machine progress, pending-input snapshots and observers, clean-versus-truncated EOF, and bundled/system provider payload. |
| [URL-library implementation](url-library.md) | Parsing and normalizing absolute/request URLs; reusable Relabel PEGs, labeled failure tuples, byte normalization, and the shared HTTP request-boundary contract. |
| [HTTP-library implementation](http-library.md) | Parsing/serving HTTP/1.1 streams; synchronous llhttp callbacks, GC-owned events, client pooling and bounded background draining, framing/keep-alive, protocol takeover, listener Interface conversion, shared-port bind forwarding, and ownership-aware request-header idle deadlines shared by listener and adopted Exchange serving. |
| [WebSocket-library implementation](websocket-library.md) | Opening and retiring WS/WSS connections; HTTP byte/ownership handoff, bounded framing and UTF-8, control-state/fairness rules, operation supervisors, and abort-before-drain cleanup. |
| [WebSocket allocation and lifetime results](websocket-allocation-results.md) | Matched operation slopes, collector latency, held-endpoint retention, generated-C allocation sites, and exact measurement provenance. |
| [WebSocket timing and fairness observations](websocket-benchmark-results.md) | Finite paired intervals, sampler and timer distributions, background activity, and measurement limits. |
| [WebSocket validation](websocket-validation.md) | Source and provider identities, Linux and local VM gates, conformance, sanitizer evidence, and reproduction instructions. |
| [Lua interop internals](lua-interop-internals.md) | Crossing generated Lua/Titan boundaries; coercive Lua versus strict branded calls, dynamic conversion, checked record/module/Array writes, metatables, loader paths, standalone entrypoints, and safety. |
| [Foreign-function implementation](foreign-functions.md) | Public C-ABI declaration metadata, runtime-resolved atomic image bindings, local source callbacks, restricted raw-C checking, exact sequencing, generated `.titan.h` headers, target-directed allocation/FAM spills, and callback ownership. |
| [FFI internals](ffi-internals.md) | Importing C headers for checked direct calls; preprocessing, C99 parsing/type extraction, `Type.C*` declarations, enums/macros, owned objects, type rendering, and platform failure modes. |
| [C FFI declarations and expressions](c-ffi-expressions.md) | Checking exact C declarations/conversions/operators with the target compiler; tag identity, declarators, numeric profiles, probe caching/clearing, object pointers, automatic/owned storage, macros, and field projection. |
| [Trusted Lua C API FFI boundary](ffi-lua-api-followup.md) | The general public-FFI exclusion, the audited standard-library exception, its operation allowlist and stack-effect ledger including native loader/provider snapshot helpers, and the remaining design work before arbitrary Titan code can use the Lua C API. |
| [Native test runner](test-runner.md) | Discovering, building, and executing native tests with `titanc --test`; generated runner, public cases/subtests/cleanup, traces, filters, aggregate ownership, regression placement, and portability gates. |
| [Native source coverage](native-coverage.md) | Source-region markers, separate coverage objects, per-object file inventories, and direct test-executable gcov/gcovr reporting. |
| [Completion analysis](completion.md) | Producing completion candidates for an unsaved module at a caret; coordinate-preserving transforms, lexical/member facts, detached descriptors, captured dependency catalogs, and host/compiler boundaries. |
| [Driver and toolchain](driver.md) | Resolving source/compiled modules and SDK/tool paths; C compilation, provider/executable linking, language-server resolver APIs, `titanc` flags, environment variables, native transports, formatting, and runtime support. |
| [Output-directory routing](output-directory.md) | Routing generated artifacts with `-o/--output`; source-root-relative layouts, headers, incremental lookup, temporary files, coverage paths, and repository build stages. |
| [Experimental Windows build](windows-build.md) | Building/verifying native Windows SDKs with CLANG64/UCRT; controlled Lua/dependency DLLs, separate output trees, UTF-8 relocation/loading, provider publication, launchers, NTFS tests, and experimental limits. |
| [Build and installation responsibilities](build-script-audit.md) | Assigning build/install responsibilities across Make and LuaRocks; installed-program bootstrap checks, native dependency recipes, copying-only publication, explicit input cleanup, and verification targets. |
| [Object-backed source modules](incremental-compilation.md) | Reusing objects and compiling separately with `--incremental`/`-c`; selected output trees, trusted source records, freshness checks, AST-free declarations/headers, and Make-owned invalidation. |
| [Folder modules](folder-modules.md) | Assembling sibling source files into one logical module; canonical main, blocked contributor imports, deterministic order, independent parsing, shared namespace/checking, and output paths. |
| [Multi-module libraries](multi-module-libraries.md) | Grouping logical modules into one physical provider pair; common-prefix selection, DSO discovery/claims, generated Lua shims, canonical runtime imports, lazy/global promotion, and validated publication. |
| [Static compiled modules](static-compiled-modules.md) | Loading/linking archive providers and constructing flattened archives; object-section interfaces, bounded ar/ELF/COFF/Mach-O readers, target/provenance validation, whole-provider composition, and paired publication. |
| [Selective binary dependency verification](binary-compatibility.md) | Checking whether an existing consumer can load a changed provider; used signatures/public shapes, ABI-first runtime verification, copied native provider selection, stable union tags, variable/closure slots, and Windows DLL launchers. |
| [Archived issue benchmarks](benchmark-archives.md) | Index of issue benchmark harnesses, C probes, raw result JSONs, and relocatable evidence archives published as GitHub pre-release ZIPs (#193, #196, #242, #252). |

## Lua-version upgrade audit

Building against Lua internals requires auditing a Lua upgrade against the
generated code, runtime, and matching headers/archive. Current representation
and barrier rules are specified in [values and the GC](values-and-gc.md);
the retained point-release audit records the evidence behind the pinned version:

* [Lua 5.5.0 → 5.5.1: exhaustive update audit](lua-5.5.1-update.md)

## Known limitations and quirks

Each chapter documents the rough edges of the part it covers — latent
bugs, raw-Lua-error crashes where a clean diagnostic was intended,
`TODO`/`FIXME` gaps, and deliberate-but-surprising boundaries. They are
collected here so a reader knows where the sharp corners are before diving
in; follow the link for the full discussion.

| Where | Limitation / quirk |
| --- | --- |
| [AST and typedecl](ast-typedecl.md#the-cost-of-adding-a-node-or-type) | No compiler-enforced exhaustiveness: a missing visitor/codegen handler for a `_tag` crashes on first contact, not at build time. Some type values (`types.Module`) [bypass `typedecl`](ast-typedecl.md#typedecllua-constructor-generation) and its arity check (whose error even says "missing" when there are too *many* args). [Decorations](ast-typedecl.md#decorations-who-writes-what-who-reads-it) are unvalidated field assignments (a typo fails only when read) and make post-checker ASTs self-referential (the `TableFormatLevel` print-hang hazard). |
| [Lexer and parser](lexer-parser.md#non-reentrancy) | The parser remains **non-reentrant**, but protects the match and clears per-parse filename, source, and location state on every exit. `goto` and `finally` remain reserved without surface productions. Every committed label needs a `syntax_errors` entry. Flat-width capture limits and genuine syntax nesting require separate regression coverage; final review inventories predicates and committed alternatives directly. |
| [The type checker](checker.md#the-relations-and-plans-in-typeslua) | Computed Map keys/values, record fields, named arguments, and parenthesized expressions are deliberately finite scalar consumers; they never become open-result sinks. [Dead code after a proven non-fallthrough statement](checker.md#non-fallthrough-analysis) is not analyzed, so a type error there goes unreported. [First-class Titan functions, closures and bound methods are supported](checker.md#per-construct-notes-for-contributors), while imported or source-defined [foreign functions](foreign-functions.md) remain direct C designators that decay only to exact C function pointers; record types and modules also remain non-values. Re-declaring a name in the same block silently shadows. [Process-global state](checker.md#process-global-state) must be reset by callers. |
| [Union implementation](unions.md#case-checking-and-control-flow) | Case coverage is optional, but complete coverage of the statically known closed union proves non-fallthrough when every arm terminates; imported hidden variants remain in `nvariants`, so visible arms alone cannot falsely establish that proof. `Type.Variant` is validated union-owned interface metadata, never a source or value-facing type. |
| [Code generator: overview](codegen-overview.md#no-c-ast-templates-utilrender-and-clang-format) | A missing template variable is a hard "Internal compiler error" abort; ordinary generated `.c` and `.titan.h` receive required `#line` normalization, while [native coverage](native-coverage.md) uses final lexical marker conversion. `--pretty-print` opts into `clang-format` with Titan's fixed style and include sorting disabled. Each release is [pinned to one Lua version](codegen-overview.md#anatomy-of-a-generated-translation-unit) (5.5.1). The [`$LOADMODULES2` re-init branch](codegen-overview.md#the-module-protocol) is emitted only for more than one dynamic dependency. |
| [Variadic parameters](variadic-parameters.md#code-generator-the-seven-structs-and-the-native-abi) | `...` is non-first-class (cannot be captured/stored/escape, invisible to inner lambdas) though the declaring function is a normal value; the homogeneous count is capped at `TITAN_VARARG_MAX = 200` (`lu_byte n_args`, an *intentional* cap, runtime-enforced). `...[i]` is typed `t` and **raises** out of range — a deliberate divergence from array `a[i]` (`t?`). `return ...` is finite projection in a fixed-result function, but it preserves a runtime-sized remainder when the enclosing function declares a flexible output tail. Descriptor payloads are untraced, so collectable elements need independent traced provenance (semantic/VM/allocation/result homes, with explicit ranges for live native outputs), never roots supplied by the descriptor itself. |
| [Code generator: constructs](codegen-constructs.md#operators-with-inlined-lua-semantics) | Numeric operators reproduce Lua 5.5 exactly: integer `+ - *`/unary `-` emit `intop(...)` for defined two's-complement wrap (no signed-overflow UB, `-fwrapv` irrelevant); mixed `integer`/`float` comparisons use the unboxed `titan_*_intfloat`/`titan_eq_intfloat` helpers and compare by mathematical value (**no promotion**). The remaining gap: the general binop fall-through evaluates its two operands in C's unspecified order, not Lua's strict left-to-right (observable only when both operands have side effects). |
| [Values and the GC](values-and-gc.md#gc-discipline-the-invariants) | Under the generational collector a missing barrier or unanchored fresh object is a reliably reproducible use-after-free, not a rare race — the discipline the whole chapter exists to enforce. Private Array writer user values and function-entry trailers add traced edges that must follow the same rooting/barrier rules. |
| [Error handling](error-handling.md) | `finally` deliberately forbids `return` and escaping `break`; a `raise` from cleanup is the sole override path. Error chaining is not modeled: a new error replaces the in-flight value and trace. The inline boundary relies on the vendored Lua 5.5 `lua_longjmp` layout staying in sync with the linked Lua build. |
| [Lua interop internals](lua-interop-internals.md#safety-summary) | Dynamic conversion is intentionally broader at written/genuine-Lua boundaries than at strict Titan observations. An ordinary Map has no Titan conversion writer for raw Lua mutation or user `__newindex` policy, so its later typed read—including a value supplied by `__index`—remains the enforcement point. Privileged C/debug code can forge or corrupt private userdata/upvalue invariants. The [reserved error slot remains dead groundwork](lua-interop-internals.md#the-two-lua-stack-entries-genluaentry). |
| [FFI internals](ffi-internals.md#platform-constraints-and-failure-modes) | Compile-time POSIX dependency (the configured `CC` probes `/dev/null` for defines and include paths); contextual C primitives and recursively exportable typedef, pointer, function, struct, and fixed-array graphs are valid serialized interface types; header-dependent declarations require a compatible explicit `foreign import` in the consumer. C unions, incomplete by-value aggregates, and flexible arrays remain ineligible for structural serialization. Bare and typedef'd enum constants import as C integer members with simple numeric values preserved, static functions are imported, and all imports share [one flat C namespace](ffi-internals.md#calls-and-variables) with no C-symbol namespacing. General function-like macros remain invisible outside the four typed `titan/ffi.h` bridges. Allocation still rejects `void`, incomplete objects, C array-typedef owners, and nested owners; a FAM struct has scalar `.new(count)` but deliberately no `.new_array`. Automatic storage has ordinary C lifetime and no escape analysis. The [C99 grammar remains non-reentrant](ffi-internals.md#typelist-extraction). Some preprocessor failures still escape as raw Lua errors rather than diagnostics. `c-parser/typed.lua` ships [disabled](ffi-internals.md#typedlua). |
| [Driver and toolchain](driver.md#module-names-and-the-search-paths) | Compile-time and run-time Titan paths share `;;` default insertion, but generated Lua shims intentionally use the independent `package.cpath` template order. Configurable compiler and flag strings use a deliberately small shell-word parser rather than full shell expansion. |

Some of these also surface in the [language reference](../language/index.md)
as user-visible behavior (e.g. integer overflow, container aliasing); the
links above point at the implementation-side discussion of the underlying
cause.

## Repository map

| Path | What it is |
| --- | --- |
| `titanc` | The compiler CLI. |
| `titan-compiler/` | The compiler proper: `lexer`, `parser`, `syntax_errors`, `ast`, `typedecl`, `checker`, `types`, `symtab`, `coder`, `driver`, `staticmetadata`, `foreigntypes`, the C-FFI `cdeclarator`/`cpreamble`/`csemantics`/`cprobe` modules, pure-Lua `sha256`, `location`, and `util`. |
| `c-parser/` | The pure-Lua C preprocessor and C99 parser behind `foreign import`. |
| `titan/` | Titan standard-library sources. They are twenty-six independent qualified `titan.*` modules linked together into the physical `titan.so` and `titan.a`; `titan.io` owns the standard Interface vocabulary and I/O helpers, `titan.url` owns reusable URL parsing, and `titan.uv`, `titan.http`, `titan.websocket`, `titan.peg`, `titan.string`, `titan.sqlite3`, `titan.json`, `titan.protobuf`, and `titan.thread` use folder ensembles. |
| `out/` | Default repository output tree: standard-provider pair and generated logical-module shims under `out/titan/`, plus native-test and coverage subtrees. `TITAN_OUTPUT_DIR` selects another stage; authored runtime objects and native dependencies retain their own build locations. |
| `titan-runtime/` | `titan.h`/`titan.c` (`RTLD_LAZY` + `RTLD_GLOBAL` generated-import loader and error handler), the reduced `minicoro.c`, and `transfer.h` (the immutable closure manifest declarations, the Protocol Buffers wire-buffer writers, and the generated nominal codec runtime); the two C objects are the exact members of runtime-SDK `libtitan.a`; separate vendored `libbacktrace.a`; `ltitanlib.c`, carried as `ltitanlib.o` into the full standard `titan.so`/`titan.a` pair and linked alone into the private bootstrap, exposing `backtrace`, internal `pin`/`clear`, compiler-local `_loadlib`, and shim-facing `_loadlibglobal`; top-level `minicoro.h`, `titan.h`, and `transfer.h`, plus the sole namespaced SDK header `titan/ffi.h`. Standard callbacks are source foreign functions, not runtime archive shims. |
| `spec/` | The Busted outer harness and native Titan standard-library suites; coder specs generate, compile, and run C. |
| `doc/` | This implementation manual, the [language reference](../language/index.md), and the [style guide](../style-guide.md). |

Start with [repository workflow](repository-workflow.md) for prerequisites,
isolated SDKs, profiles, and commands. [AGENTS.md](../../AGENTS.md) is the
compact agent routing and policy guide; the implementation chapters own the
operational and technical detail.
