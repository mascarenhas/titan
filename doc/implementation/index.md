# The Titan compiler and runtime

This manual documents how Titan is implemented: a compiler written in Lua that
translates `.titan` modules into C built against the **internals** of the Lua
interpreter, together with a small C runtime-support library. It is written for
contributors changing the compiler, runtime, or standard library. For the
language itself, see [*The Titan Programming Language*](../language/index.md).

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
one or more C translation units per logical module (plus `<stem>.priv.h` when split)
   │  clang-format             (opt-in --pretty-print; fixed explicit style)
   │  #line normalization      (ordinary mode; coverage uses final lexical
   │                            marker conversion instead)
   │  driver.compile           (driver.lua — writes part .c/.priv.h files
   │                            and invokes cc per part)
   ▼
object files ──► one common-prefix provider.so/provider.a (no Lua files; Lua
             │   reaches it through the Titan package searcher)
             └─► driver.compile_program → executable (when a main() exists)
```

`titanc` orchestrates the pipeline: it locks the output domain, plans the
module closure, certifies reusable source objects in-process (`--incremental`),
compiles misses in parallel worker processes under a single job-slot ledger,
compiles `--c-source` nodes, and gates runner/entrypoint synthesis and linking
with a final-link certificate, while `-c` stops at object/header emission
([driver and toolchain](driver.md), [build coordinator](build-coordinator.md)).

Two invariants shape everything downstream of the checker:

* **Generated code bypasses the Lua C API.** It includes Lua's internal
  headers (`lobject.h`, `ltable.h`, `lvm.h`, …) and manipulates values,
  tables, and the stack directly. That gives Titan its speed and ties each
  compiler release to one Lua version — currently **Lua 5.5.1** (staged in the
  SDK at `<root>/src/lua-5.5.1`, or `./lua-5.5.1/src` in a checkout; see
  [Lua installation](driver.md#lua-installation-and-executable-relative-search-paths)).
* **Titan data is Lua data.** Every ordinary Titan value is representable as a
  Lua value, and generated allocations obey Lua's generational collector
  invariants: fresh objects are anchored in stack slots and mutations emit the
  required write barriers. Direct C FFI locals and native nominal fields are
  the deliberate exception, boxing only at a dynamic boundary.

## Reading guide

### Workflow, Build & CI

| Chapter | Covers |
| --- | --- |
| [Repository development workflow](repository-workflow.md) | Isolated prefixes, profile and environment hygiene, repository make/test commands, checkout-Lua Busted runs, output routing, and shared-artifact ownership. |
| [Build and installation responsibilities](build-script-audit.md) | Makefile and LuaRocks ownership: Lua and native dependency preparation, `titanc --incremental` delegation, job pools, `make browser-sdk`, install targets, and [module rock publication/removal](build-script-audit.md#module-rock-publication-and-removal). |
| [Continuous integration and platform validation](continuous-integration.md) | Linux lanes, four-way coverage shards, `browser-toolchain`/`browser-stdlib`/`browser-playwright`/`browser-packaging` jobs, caches, sanitizers, and macOS pre-merge gates. |
| [Experimental Windows build](windows-build.md) | Stock Lua DLL and SDK recipe, UTF-8 relocation, `titanc.exe` launcher, DLL publication, NTFS test ownership, and Windows runtime limits. |
| [Native test runner](test-runner.md) | `--test-dir` discovery, certified-object case discovery, synthetic runner, browser stdlib test images, parallel aggregate groups, and regression placement. |
| [Native source coverage](native-coverage.md) | Lexical marker `#line` conversion, `.coverage` object separation, compiler flags, counter dump/reset, gcov/gcovr reports, and serial Make targets. |
| [Standard-library implementation rules](standard-library-maintenance.md) | Contributor rules for stdlib modules: declaration ownership, browser subset parity, Titan-first C/Lua/JS layering, call/result modeling, and boundary tests. |
| [Archived issue benchmarks](benchmark-archives.md) | Index of benchmark pre-release ZIP archives, SHA-256 verification steps, and commit permalinks to retired measurement and audit chapters. |

### Lexer, Parser & Type Checker

| Chapter | Covers |
| --- | --- |
| [AST and typedecl](ast-typedecl.md) | `typedecl` constructors, `_tag` dispatch, source locations, full AST node inventory, pass-owned decorations, and add-a-node checklists. |
| [Lexer and parser](lexer-parser.md) | Scannerless LPegLabel grammar, longest-match rules, foreign-body grammar, fold captures, precedence, desugarings, error labels, and non-reentrancy. |
| [The type checker](checker.md) | Checker entry contract, speculative C-probe barrier and authoritative recheck, symbol table, staged collection, initializers, AST rewriting, and global state. |
| [Type relations and boundary plans](type-relations-and-boundaries.md) | Consistency versus coercion, strict guards, dynamic conversion, C scalar rules, written casts, boundary matrix, and checker-owned plans. |
| [Const-value implementation](const-values.md) | `const` locals and fields, initializer-only write authority, Interface snapshots, concrete Array construction, optional maybe-const views, and linear-use freeze proofs. |
| [Generics](generics.md) | Rigid checking, local type inference, declared/erased-graph validation, Interface constraint erasure, [container views and Option adjustment](generics.md#container-views-and-presence), FFI admission, metadata serialization, and async owners. |
| [Interfaces](interfaces.md) | Structural satisfaction, frozen conversion and adapter plans, wrapper userdata layout, four dispatch paths, metatable identity, downcasts, and separate compilation. |
| [Union implementation](unions.md) | Parser lowering, variant descriptors, visibility, payload eligibility, `case` checking and non-fallthrough, runtime layout, dispatch, Lua exposure, and schemas. |
| [Record constructors](record-constructors.md) | Record-call desugaring, custom `new` overrides, private literal construction authority, provider metadata, Lua namespace calls, and stdlib usage. |
| [Type aliases](type-aliases.md) | Lazy resolution in the type namespace, foreign aliases, serialized `type_members`, and preserved nominal member lookup across providers. |
| [Named arguments](named-arguments.md) | `ArgsNamed*` parser nodes, declaration `paramnames`, C prototype parameter names, checker normalization, evaluation order, and missing-field synthesis. |
| [Explicit source-import collaboration interfaces](source-import-visibility.md) | `.titan` import markers, logical identity, loader views, checker staging, inherited C headers, private state sharing, and binary boundary rules. |
| [Documentation comments](documentation-comments.md) | LDoc comment attachment rules, detached document contract, declaration binding, `Documented` serialization, and language-server hover/completion export. |
| [Completion analysis](completion.md) | Coordinate-preserving source transforms, foreign type leaves, lexical and member candidates, detached saved descriptors, and private editor analysis. |

### Code Generation, GC & ABI

| Chapter | Covers |
| --- | --- |
| [Code generator: overview](codegen-overview.md) | C templates, name mangling, split translation units, native calling convention, closures, module protocol, ABI metadata, dependency wiring, and Lua upgrades. |
| [Values and the GC](values-and-gc.md) | `TValue` and Lua stack layout, C types of Titan values, nominal userdata, generational GC invariants, caller-rooted inputs, and write barriers. |
| [Native nominal storage](nominal-storage.md) | Traced versus native record/union regions, embedded fixed C objects, trailing buffers, direct fresh construction, exact native options, and callback access. |
| [Dense Arrays](dense-arrays.md) | Backing/proxy userdata pair, deterministic `lenhint` length, writers, strict reads and writes, `const` snapshot/freeze lowering, and GC barriers. |
| [Code generator: constructs](codegen-constructs.md) | Per-construct C lowering for locals, assignment order, loops, Maps, strings, operators, casts, `is`, calls, and runtime error messages. |
| [Closure adjustment wrappers](closure-adjustment-wrappers.md) | Callable shape adaptation, `nil_fill_result`, frozen adapter plans, wrapper eligibility and layout, native adapters, strict relays, and GC rooting. |
| [Immediately called anonymous functions](immediate-functions.md) | Inline lowering of immediately invoked lambdas: eligibility rules, inline return destinations, result demand, conversion edges, captures, and rooting. |
| [Variadic parameters](variadic-parameters.md) | `...: T` parser encoding, `varargtype` scoping, `TitanVarg*` descriptor ABI, checked C-scalar boxing into `value` varargs, and payload rooting. |
| [Flexible returns and contextual `value` calls](flexible-returns.md) | Representation of open return tails, finite/open result demand, callable adjustment, generated result runs, Lua-stack entries, and pending-return lifetimes. |
| [Spread expressions](spread-expressions.md) | `ExpSpread` ownership, checker planning, generated carrier and result runs, element reads with GC roots, and open-sink preflight. |
| [Error handling](error-handling.md) | Trace pinning, libbacktrace/fallback/browser trace backends, inline `setjmp` boundaries, pending control actions, volatile recovery spills, and unwind landings. |
| [Defer](defer.md) | `defer` grammar, iterative AST lowering into `StatTry` `finally` blocks, and defer-tail lexical scoping. |

### FFI, Lua C API & Browser Runtime

| Chapter | Covers |
| --- | --- |
| [Lua interop internals](lua-interop-internals.md) | Dual Lua-stack entries, dynamic conversion of containers and nominal types, module metatables, registry footprint, loading paths, and boundary safety. |
| [FFI internals](ffi-internals.md) | Header preprocessing and parsing, `#pragma once`, semantic header identities, TypeList extraction, `titan/ffi.h` bridges, C calls/casts, and owned storage. |
| [C FFI declarations and expressions](c-ffi-expressions.md) | C tag identity, declarators, target arithmetic profile, batched acceptance probes and caching, counted byte copies, FAM allocation, macros, and enums. |
| [Foreign-function implementation](foreign-functions.md) | Raw-C foreign-body grammar and checking, C99 literal/operator typing, allocation plans, `.titan.h` export planning, sequencing, and stdlib callbacks. |
| [Trusted Lua C API boundary](ffi-lua-api-followup.md) | Audited stdlib-only discipline for direct Lua C API calls, per-operation stack/root ledgers, and why it stays outside public FFI. |
| [Browser target](browser-target.md) | `--target browser` architecture: Emscripten pin, browser Lua and SDK, subset parity gate, JSPI runtime, byte channels, trace tables, and validation suites. |
| [Browser bridge runtime](browser-bridge.md) | Generated browser launcher, `titan.browser` foreign entries and pin table, JS file ownership, `BrowserValue` marshalling, synchronous callbacks, and `fetch`/`websocket` sources. |
| [Browser analysis and semantic packs](driver.md#browser-analysis-target) | Tool-free type checking against the Wasm archive, lazy Emscripten probes, cache identities, and [offline semantic-pack publishing](browser-target.md#publishing-the-browser-semantic-pack). |
| [Windows-host browser builds](browser-target.md#windows-and-other-hosts) | Shared browser SDK recipes and Wasm validation on Windows hosts, Emscripten discovery, and per-engine runner job ownership. |
| [Browser Wasm-EH longjmp contract](browser-target.md#wasm-eh-longjmp-contract) | `SUPPORT_LONGJMP=wasm` and `WASM_LEGACY_EXCEPTIONS=1`, ambient flag isolation, EH fingerprints, stale-record refusal, and protected JSPI suspension. |

### Build Coordinator, Incremental Cache & Providers

| Chapter | Covers |
| --- | --- |
| [Driver and toolchain](driver.md) | Module lookup, loaders, Titan path and SDK fallback, language-server API, C compile/link dispatch, job scheduler/jobserver, `titanc` flags, and `titan-runtime/`. |
| [Compiler-owned build coordinator](build-coordinator.md) | `.titan-build.lock`, closure planning, preflight, `titan-build-worker-v1` RPC, job-slot ledger, staged publication, `--c-source` nodes, final-link certificates, and `--test-dir`. |
| [Output-directory routing](output-directory.md) | `-o`/`--output` and `--exe` path mapping, lock domains, `.titan`/`.native`/`.titan-links` state directories, temporary files, and coverage artifact routing. |
| [Object-backed source modules](incremental-compilation.md) | `--incremental` and `-c` `.titan.source` certificates, persistent digest cache, root relocation, semantic header revalidation, miss codes, split parts, and LTO. |
| [Folder modules](folder-modules.md) | Folder main and contributor discovery, deterministic declaration order, single-AST assembly, canonical output stems, and standard-library ensembles. |
| [Target source selection](target-source-selection.md) | `source_selection.lua` variant filename classification, `-T`/`TITAN_TARGET` selection rows, folder sweeps, cache admission, logical stems, and Make inventories. |
| [Multi-module libraries](multi-module-libraries.md) | Common-prefix `.so`/`.a` provider selection, shared candidate search with the package searcher, canonical imports, validated publication, and the stdlib image. |
| [Static compiled modules](static-compiled-modules.md) | Archive metadata and import inventories, native dependency closure, container readers, target fingerprints, and provider validation. |
| [The linked provider set](codegen-overview.md#the-linked-provider-set) | Private per-state executable catalog (Unix, Windows, and browser Wasm on demand) that supplies reached archive members, app-owned source modules, and selected external required providers without initializing them early or publishing Lua loaders. |
| [Selective binary dependency verification](binary-compatibility.md) | Consumer-used compatibility projections, construction and closed-union proofs, generated load-time verification exports, and provider-owned ABI slots. |

### Standard-Library Internals

| Chapter | Covers |
| --- | --- |
| [Coroutines](coroutines.md) | `titan.coroutine`: minicoro SELF/BACK routing, transfer roots, trace outcomes, native stacks and JSPI browser backend, retirement, and abandoned-stack unwind. |
| [Async runtime and public libuv ownership](libuv-runtime.md) | `titan.async`: Task scheduler over public UV, browser driver, Completion/subscription/external waits, native retirement, receivers, workers, and Lua-state close. |
| [Extending the libuv binding](libuv-extension-guide.md) | Adding `uv_*` wrappers and Task adapters: native owners, foreign callback boundary, synchronization entries, external wake bridge, socket handoff, and teardown. |
| [Thread-library implementation](thread-library.md) | `titan.thread`: bounded MPMC ring over external wake, registration pins, state-close withdrawal, endpoint release chain, OS-join retirement, and `Group` coordination. |
| [Transfer-policy implementation](transfer-library.md) | `titan.transfer`: packet layout and classification, raw-slot decode, closure snapshots, scoped endpoint resource table, manual handoff, and browser same-instance limits. |
| [I/O-library implementation](io-library.md) | `titan.io`: target-shared interface facade, one-write `print` through current `os.stdout`, and owned `io.lines` iteration and close paths. |
| [Operating-system library implementation](os-library.md) | `titan.os`: native/browser clock, environment, and parent-stream contributors, process spawn rollback, captured streams, signals, transfer/disposal, and shell ownership. |
| [Lexical filesystem paths](standard-library-path.md) | `titan.path`: shared Titan/Lua lexical normalization, POSIX/Windows grammar selection, Windows volume/namespace parsing, and deliberate differences from Go. |
| [Filesystem-library implementation](filesystem-library.md) | `titan.fs`: descriptor ownership, one-shot async UV requests, Lua-state close abandonment, `File` transfer, metadata/canonical paths, and `Watcher` buffering. |
| [DNS and TCP implementation](libuv-networking.md) | `titan.net`: DNS/TCP policy above UV/async, one-shot requests, dialing and listening, persistent and demand-driven reads, accept delivery, and connection transfer. |
| [TLS-library implementation](ssl-library.md) | `titan.ssl`: OpenSSL over `net.Connection`, trust contexts, PEM decoding, BIO ownership, duplex state machine, shutdown/EOF, transfer, and OpenSSL build modes. |
| [URL-library implementation](url-library.md) | `titan.url`: stored Relabel PEG parsing and normalization, labeled failure position tuples, and separate request-component boundaries. |
| [HTTP-library implementation](http-library.md) | `titan.http`: `RequestOptions`, native redirects, llhttp callback bridge, client pooling, upgrades, server keep-alive Tasks, transfer, and browser `titan:fetch` client. |
| [WebSocket-library implementation](websocket-library.md) | `titan.websocket`: HTTP upgrade handoff, bounded framing and UTF-8, control priority, operation lifetimes, connection transfer, and browser `titan:websocket` client. |
| [String-library implementation](string-library.md) | `titan.string`: exact-byte operations, `format`/`pack` translation, regex compilation over `titan.peg`, match projection, `Writer` streams, and rooting. |
| [LPegLabel embedding and `titan.peg`](lpeglabel-embedding.md) | Vendored LPegLabel namespacing, typed Titan boundary, construction budgets and string labels, match adapter, Relabel translation, and provider payload. |
| [Mathematical-library implementation](math-library.md) | `titan.math`: fixed numeric wrappers over C99 math, xoshiro256** PRNG port, and length-bounded numeral parsing. |
| [Iteration-library implementation](iteration-library.md) | `titan.iteration`: `lua_next` stack ledger, generic erasure, generic-`for` iterator tuple, and closed projections. |
| [Garbage-collection library implementation](gc-library.md) | `titan.gc`: weak-mode and finalizer stack ledgers, finalizer marking, the `gc.finalizable<\|value\|>` idiom, and collector controls. |
| [Lua-state and loading library implementation](lua-library.md) | `titan.lua`: native/browser composition, synchronous browser states, preload snapshots, Receiver bootstrap, protected execution, native workers, and `load`/`require`. |
| [Reflection-library implementation](standard-library-reflect.md) | `titan.reflect`: metadata ownership, descriptor hydration, constructor compatibility, generated field accessors, native projections, value classification, and owned C storage. |
| [JSON-library implementation](json-library.md) | `titan.json`: whole-document PEG parser, fold budgets, error locations, exact scalar conversion, reflection mapping, and shared writer resource policy. |
| [Protocol Buffers-library implementation](protobuf-library.md) | `titan.protobuf`: reflective and generated codecs, portable copied-data policy, cached schemas, `TitanValue` fields, wire decoding, nesting limits, and anonymous roots. |
| [SQLite-library implementation](sqlite3-library.md) | `titan.sqlite3`: native packet boundary, worker reservations and lifetimes, connection transfer, cancellation, abandoned state-close waits, and reflected row decoding. |

## Upgrading Lua

The pinned-Lua upgrade procedure is in
[codegen-overview](codegen-overview.md#upgrading-the-pinned-lua).

## Known limitations and quirks

Contributor hazards in the current implementation; each row links to the
owning section.

| Where | Contributor hazard / quirk |
| --- | --- |
| [AST and typedecl](ast-typedecl.md#the-cost-of-adding-a-node-or-type) | No compiler-enforced visitor exhaustiveness: a missing handler crashes on first contact, and some coder chains (`codeassignment`, `codefuncdec`) have no terminal error. Post-checker ASTs are self-referential (`TableFormatLevel` hazard). |
| [Lexer and parser](lexer-parser.md#non-reentrancy) | `parser.parse` is non-reentrant and asserts that no parse is active. `goto` and `finally` are reserved words without surface statements. |
| [The type checker](checker.md#non-fallthrough-analysis) | Dead statements after a proven non-fallthrough statement are unchecked. Re-declaring a local in the same block overwrites the earlier binding. [Process-global state](checker.md#process-global-state) must be reset between checks. |
| [Code generator: overview](codegen-overview.md#compiled-module-abi) | Generated nominal codecs have no load-time ABI check, and `titan.protobuf`'s handoff entry is type-checked only once at init — every provider must be built against one SDK. Missing template variables abort with an ICE. |
| [Variadic parameters](variadic-parameters.md#gc-discipline-descriptor-pointers-and-untraced-payloads) | `TitanVarg*` descriptor payloads are untraced (elements need independent roots) and capped at `TITAN_VARARG_MAX = 200`. |
| [Values and the GC](values-and-gc.md#gc-discipline-the-invariants) | Under Lua's generational collector, a missing write barrier or an unanchored fresh allocation causes reproducible use-after-free bugs. |
| [Dense Arrays](dense-arrays.md#failure-and-performance-boundaries) | Debug-library or raw C API code can corrupt the private backing/proxy cycle, writer, or `lenhint` without runtime detection. |
| [Error handling](error-handling.md#setjmp-sensitive-localparameter-spills) | Volatile address-exposed recovery homes rely on GCC/Clang guarantees rather than strict ISO C; whole-program LTO exposing Lua's error machinery requires requalification. |
| [C FFI declarations and expressions](c-ffi-expressions.md#longjmp-safe-aggregate-spills) | Untracked raw aliases and asynchronous C writes sit outside the tracked mutable-out recovery guarantee. |
| [Coroutines](coroutines.md#unwinding-an-abandoned-coroutine) | All translation units must share one sanitizer configuration. Abandoned-coroutine unwind relies on structured-entry invariants (violations abort), skips foreign C frames and non-protocol providers, and runs inside a non-yielding finalizer; Windows Fiber stack bounds are unvalidated. |
| [Async runtime: Lua-state close](libuv-runtime.md#lua-state-close-of-an-unretired-runtime) | State close unwinds parked Tasks and runs closure-registered `unregister` hooks inside a finalizer where awaiting, yielding, or starting a Runtime is forbidden and newer objects may already be finalized. |
| [Filesystem library: Lua-state close](filesystem-library.md#lua-state-close) | A `File` whose in-flight read, write, or flush is abandoned by Lua-state close leaks its OS descriptor until process exit so the worker never writes to a recycled fd. |
| [Transfer policy](transfer-library.md#packet-scoped-resource-table-titan_transfer_resource_table) | The packet resource table does not collect cross-channel cycles. Holding a [decode context past its decode](transfer-library.md#registration-attachment-and-claim) raises when idle, but reuse on a pooled frame during a later decode is undetected. |
| [Lua interop internals](lua-interop-internals.md#safety-summary) | Container boundaries validate only the outer representation; debug or C code can break private user-value, upvalue, and metatable invariants. |
| [Type relations and boundary plans](type-relations-and-boundaries.md#failure-contract-and-ffi-boundary) | Raw C pointers box as untyped light userdata, and `value as` raw-pointer casts are unchecked reinterpretations. |
| [Const values](const-values.md#array-relations-and-linear-use-analysis) | `array_freeze` falls back to copying unless `checker/linear.lua` proves one of two narrow last-reference patterns (a builder local or fresh top-level return). |
| [FFI internals](ffi-internals.md#platform-constraints-and-failure-modes) | Header preprocessing depends on a POSIX preprocessor and a GNU/Clang header subset; some preprocessor errors raise raw Lua errors; the C99 grammar is non-reentrant. |
| [LPegLabel embedding](lpeglabel-embedding.md#construction-accounting-and-string-labels) | `behind` checks only projected tree size; the C engine alone enforces the capture-free, fixed-length, 255-byte look-behind limit. |
| [Driver and toolchain](driver.md#module-names-and-the-search-paths) | Without the native `titan` support module (or on Windows volumes lacking `ChangeTime`/file IDs), file observations fall back to coarse timestamps and re-hash headers per pass. The [SDK fallback](driver.md#the-run-time-titan-path-and-sdk-fallback) `titanc --print-root` query has no timeout. |
| [Driver and toolchain](driver.md#gnu-make-jobserver-participation) | Recipes without `+` under GNU Make 4.4 serialize to one job; pre-4.2 Make (macOS stock 3.81) cannot share pipe jobservers or show `-j1` (see [Make job pool](build-script-audit.md#make-job-pool-and-titanc-recipes)); Windows ignores parent jobservers; a `SIGKILL`ed `titanc` leaks borrowed tokens. |
| [Object-backed source modules](incremental-compilation.md#build-and-validation-ownership) and [Build coordinator](build-coordinator.md) | Whole-interface digests are conservative (compiler comments invalidate all objects); split-part names up to `--c-parts` are reserved even for unsplit modules; same-size rewrites within one tick of a [coarse-timestamp filesystem](incremental-compilation.md#fresh-verification-contexts) can hide edits; `.titan-build.lock` covers local filesystems only. |
| [Multi-module libraries](multi-module-libraries.md#validated-publication) | The Titan searcher runs after Lua's searchers, so a provider directory on `package.cpath` or a stale `.lua` file on `package.path` shadows it. |
| [Static compiled modules](static-compiled-modules.md#publication-and-installation) | Archive and provider publication is recoverable within the process, not crash- or power-loss-atomic. |
| [Browser target](browser-target.md#scope) | Cross-heap JS/Lua cycles are not collected; production inlining can drop physical stack frames and WebKit/Safari has reduced trace fidelity; Lua's C-call limit is capped at 100; [browser analysis](driver.md#browser-analysis-target) checks types without compiling an image. |
| [Binary compatibility](binary-compatibility.md#generated-exports-and-runtime-verification) | Load-time verification is a protocol between generated providers, not a security sandbox for untrusted DSOs. |
| [Windows build](windows-build.md#test-ownership-and-keep-going) | The Windows native test aggregate runs in one serial process; only Unix splits it into parallel owner groups. |
| [Native source coverage](native-coverage.md#direct-execution-and-reports) | Coverage counts Titan executable lines only with no denominator exclusions; timing-sensitive paths can vary between runs. |
| [OS and networking libraries](os-library.md#shell-stream-transfer) | On Windows, live shell pipes and persistent-read sockets reject transfer while overlapped reads are pending (fresh sockets need one yield; see [TCP transfer](libuv-networking.md#connection-transfer-ownership)). Closing a shell stream [does not terminate](os-library.md#shell-process-stream) descendants. [WebSocket fairness](websocket-library.md#protocol-state-and-fairness) has no starvation bound, and [TLS](ssl-library.md#contexts-and-trust) omits CA directories, platform trust stores, and encrypted keys. |

## Repository map

| Path | What it is |
| --- | --- |
| `titanc` | Compiler CLI ([command line](driver.md#the-titanc-command-line)). |
| `titan-compiler/` | Lua compiler sources: lexer/parser, AST, checker, coder, driver, browser target/link/trace/entry services, build coordinator, incremental cache, C-FFI modules, and utilities. |
| `c-parser/` | Pure-Lua C preprocessor and C99 parser behind `foreign import`. |
| `titan/` | Standard-library sources: 26 native roots linked into `titan.so`/`titan.a`, and 21 browser modules (including browser-only `titan.browser`); see [root list](multi-module-libraries.md#reserved-titan-and-the-standard-library-image) and [browser standard library](browser-target.md#the-browser-standard-library). |
| `titan-runtime/` | C runtime (`titan.h`/`titan.c`, `titan_path.c`, `minicoro`, `transfer.h`, `ltitanlib.c`, Windows launcher, SDK `titan/ffi.h`) and `titan-runtime/browser/` (JS libraries, loader, runner, trace header). |
| `out/` | Default repository build output tree ([output-directory routing](output-directory.md)). |
| `spec/` | Busted outer harness (parser, checker, coder, build, browser) and native Titan standard-library test suites. |
| `scripts/` | Tooling outside the compiler: installer/uninstaller, browser SDK/stdlib/import checks, executable documentation checks (`doc_check.lua`), and Windows build scripts. |
| `doc/` | This implementation manual, [*The Titan Programming Language*](../language/index.md), and the [style guide](../style-guide.md). |

Start with [repository workflow](repository-workflow.md) for prerequisites,
isolated SDKs, profiles, and commands. [AGENTS.md](../../AGENTS.md) is the
compact agent routing and policy guide; the implementation chapters own the
operational and technical detail.
