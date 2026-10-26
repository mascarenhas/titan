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
one or more C translation units per logical module (plus `<stem>.priv.h` when split)
   │  clang-format             (opt-in --pretty-print; fixed explicit style)
   │  #line normalization      (ordinary mode; coverage uses final lexical
   │                            marker conversion instead)
   │  driver.compile           (driver.lua — writes part .c/.priv.h files
   │                            and invokes cc per part)
   ▼
object files ──► one common-prefix provider.so/provider.a + generated Lua shims
             └─► driver.compile_program → executable (when a main() exists)
```

`titanc` orchestrates the pipeline: it locks the output domain, plans the
module closure, certifies reusable source objects in-process (`--incremental`),
compiles misses in parallel worker processes under a single job-slot ledger,
compiles `--c-source` nodes, and gates runner/entrypoint synthesis and linking
with a final-link certificate, while `-c` stops at object/header emission
([driver and toolchain](driver.md), [build coordinator](build-coordinator.md)).

Two facts shape everything downstream of the checker:

* **Generated code bypasses the Lua C API.** It includes Lua's internal
  headers (`lobject.h`, `ltable.h`, `lvm.h`, …) and manipulates values,
  tables and the stack directly. That is where Titan's speed comes from,
  and it ties each compiler version to one specific Lua version —
  currently **Lua 5.5.1**. Installed compilers use the matching internal
  source tree staged in the Titan SDK at `<root>/src/lua-5.5.1`; repository checkout mode uses
  `./lua-5.5.1/src` (see [Lua installation](driver.md#lua-installation-and-executable-relative-search-paths)).
* **Titan data is Lua data.** Every ordinary Titan value is representable as
  a Lua value, and generated GC allocations obey Lua's generational
  collector invariants: fresh objects are anchored in stack slots and writes
  receive the required barriers. Direct C FFI locals are the deliberate
  exception: exact native scalars and eligible fixed aggregates can live in
  nominal payloads, with checked boxing only at a real dynamic boundary.

## Reading guide

| Chapter | Covers |
| --- | --- |
| [Repository development workflow](repository-workflow.md) | Read before running repository builds or tests; covers isolated prefixes, profile and environment hygiene, the command table with its job-pool and test-parallelism settings, checkout-Lua Busted runs, output routing, and fixture/shared-output ownership. |
| [Continuous integration and platform validation](continuous-integration.md) | Read before changing CI; covers Linux lanes and explicit concurrency caps, the four-way covered compiler shard plan and its exclusive phase, stdlib coverage and packaging, caches, sanitizer diagnostics, and the macOS pre-merge gate. |
| [Standard-library implementation rules](standard-library-maintenance.md) | Read before changing any stdlib module; covers declaration ownership, cached invariants, counted FFI storage, narrow Lua/C boundaries, callback/result protocol shape, and test placement. |
| [Documentation comments](documentation-comments.md) | Read before changing doc comments or hover; covers LDoc attachment rules, the detached document contract, declaration binding, `Documented` serialization, and hover/completion export. |
| [AST and typedecl](ast-typedecl.md) | Read before adding or changing AST nodes or types; covers `typedecl` constructors, `_tag` dispatch, locations, the node inventory, pass-owned decorations, add-a-node checklists, and spec AST comparison. |
| [Lexer and parser](lexer-parser.md) | Read before changing syntax; covers the scannerless LPegLabel grammar, longest match, committed alternatives and bounded lookahead, fold captures and precedence, desugarings, error labels, locations, and non-reentrancy. |
| [The type checker](checker.md) | Read before changing type checking; covers the entry contract, the speculative C-probe barrier and authoritative recheck, symbol table, staged collection, `types.lua` relations and plans, AST rewriting, options, closures, non-fallthrough, imports, and process-global state. |
| [Const-value implementation](const-values.md) | Read before changing const; covers const bindings, fields and Arrays: descriptors, initializer-only authority, write rejection, Interface fields, linear-use freeze proofs, and the runtime Array pair. |
| [Explicit source-import collaboration interfaces](source-import-visibility.md) | Read before changing `.titan` imports; covers the marker and logical identity, loader views, checker staging, inherited C headers, private module state, and the binary boundary. |
| [Type relations and boundary plans](type-relations-and-boundaries.md) | Read before changing assignability, casts, or comparisons; covers consistency versus coercion, strict guards, dynamic coercion, C scalar conversions, written casts, the boundary matrix, and checker-owned plans. |
| [Generics](generics.md) | Read before changing generics; covers staging and rigid checking, local inference, declared-graph freezing, memoized erased-graph validation, constraint erasure, boundary casts, FFI admission, the erased-core coder boundary, metadata, and async owners. |
| [Closure adjustment wrappers](closure-adjustment-wrappers.md) | Read before changing non-exact callable adjustment; covers `nil_fill_result`, frozen adapter plans, wrapper eligibility and layout, native adapters, strict relays, and rooting. |
| [Interfaces](interfaces.md) | Read before changing Interfaces; covers structural satisfaction, frozen conversion and adapter plans, wrapper layout, native entries, the four dispatch paths, metatable identity, downcasts, and separate compilation. |
| [Named arguments](named-arguments.md) | Read before changing named calls; covers parser `ArgsNamed*` nodes, declaration `paramnames`, C prototype names, checker normalization, evaluation order, and record missing-field synthesis. |
| [Record constructors](record-constructors.md) | Read before changing record construction; covers call desugaring and `new` overrides, raw construction authority, semantic metadata across providers, Lua namespace calls, and standard-library use. |
| [Type aliases](type-aliases.md) | Read before changing type aliases; covers lazy resolution in the type namespace, foreign aliases, serialized `type_members`, and nominal member lookup across providers. |
| [Union implementation](unions.md) | Read before changing unions; covers parser lowering, descriptors, visibility, payload eligibility, `case` checking and non-fallthrough, run-time layout, generated dispatch, Lua exposure, and serialized schemas. |
| [Code generator: overview](codegen-overview.md) | Read before changing generated-C structure; covers templates, names, translation-unit parts and module-private storage, entry roles and the native calling convention, closures, the module protocol and ABI, pinned-Lua upgrades, dependency wiring, and user-value slots. |
| [Values and the GC](values-and-gc.md) | Read before touching GC-visible generated code; covers `TValue` and stack background, the C type of each Titan value, record/union/Interface/module userdata, the GC invariants, and call-result rooting. |
| [Native nominal storage](nominal-storage.md) | Read before changing record/union layout; covers traced and native regions, fixed objects and borrowed projections, fresh constructor storage, exact native options, ABI, and native-owner callback access. |
| [Dense Arrays](dense-arrays.md) | Read before changing Array representation or lowering; covers the backing/proxy pair, `lenhint` length, writers, reads and writes, const copy/freeze, and barriers. |
| [Code generator: constructs](codegen-constructs.md) | Read before changing per-construct lowering: locals and assignment order, loops, Maps, strings, operators, casts, `is`, calls, and run-time error messages. |
| [Immediately called anonymous functions](immediate-functions.md) | Read before changing immediate-call lowering; covers eligibility, inline return destinations, demand, conversion edges, captures, and roots. |
| [Variadic parameters](variadic-parameters.md) | Read before changing `...: t`; covers parser encoding, `varargtype` and scope, shared result demand, the `TitanVarg*` descriptor structs and native ABI, and untraced descriptor payloads. |
| [Flexible returns and contextual `value` calls](flexible-returns.md) | Read before changing flexible returns or `value` calls; covers representation, finite/open demand, callable adjustment, generated result runs, Lua-stack entries, pending-return lifetimes, and serialization. |
| [Spread expressions](spread-expressions.md) | Read before changing spread; covers `ExpSpread` ownership, checker planning, the generated carrier and result run, element reads and GC ownership, and sink preflight. |
| [Error handling](error-handling.md) | Read before changing tracebacks or catch/defer lowering; covers the error handler, trace pinning, libbacktrace merging, inline setjmp boundaries, pending actions, recovery spills, and unwind landings. |
| [Defer](defer.md) | Read before changing `defer`; covers the grammar, iterative lowering to `StatTry`, and defer-tail scope. |
| [Coroutines](coroutines.md) | Read before changing `titan.coroutine`; covers the minicoro split, transfer rooting, the entry trampoline, private trace staging and public transfer outcomes, tagged nesting, stacks, and unwinding of abandoned suspended coroutines. |
| [I/O-library implementation](io-library.md) | Read before changing `titan.io`; covers one-write `print`, ReaderCloser line iteration and loop close paths, and ordinary public OS/string imports. |
| [Operating-system library implementation](os-library.md) | Read before changing `titan.os`; covers process and host policy above UV/async: spawn transaction and rollback, parent stdio classification (including connected TCP and Windows socket rejection), captured streams, TCP output shutdown, signals, process-stream transfer and public payload disposal, shell-process ownership and transfer, and graceful exit. |
| [Lexical filesystem paths](standard-library-path.md) | Read before changing `titan.path`; covers lexical normalization shared by Titan and Lua, grammar selection, Windows volumes and namespaces, and intentional differences from Go. |
| [Filesystem-library implementation](filesystem-library.md) | Read before changing `titan.fs`; covers descriptor ownership, one-shot requests, Lua-state close, File transfer, metadata and canonical paths, and Watcher buffering, drain mapping, and retirement. |
| [Async runtime and public libuv ownership](libuv-runtime.md) | Read before changing `titan.async`; covers Task scheduling over public UV, Completion lifecycle, wait policies, subscriptions, external waits, native retirement, receivers, workers, allocation profile, shutdown, and state close. |
| [Extending the libuv binding](libuv-extension-guide.md) | Read before adding `uv_*` bindings or Task adapters; covers native owners, the foreign callback boundary, synchronization entries, the external wake bridge, adapters, final-state abandonment, socket/pipe handoff, and validation. |
| [LPegLabel embedding and `titan.peg`](lpeglabel-embedding.md) | Read before changing `titan.peg`; covers the vendored engine and namespacing, the typed boundary, construction limits and string labels, the match adapter, Relabel translation, and the provider payload. |
| [String-library implementation](string-library.md) | Read before changing `titan.string`; covers exact-byte storage, format/pack translation, regex parsing and continuation compilation over `titan.peg`, match projection, writers, and roots. |
| [Mathematical-library implementation](math-library.md) | Read before changing `titan.math`; covers fixed numeric signatures over C99, the xoshiro256** port, and length-bounded numeral parsing. |
| [Lua-state and loading library implementation](lua-library.md) | Read before changing `titan.lua`; covers independent states, preload snapshots, Receiver bootstrap, `TransferValue` carriers, protected execution, worker cancellation, host-state close during `run_async`, current-state `load`, Reader/File ownership, and asynchronous `require`. |
| [Thread-library implementation](thread-library.md) | Read before changing `titan.thread`; covers the channel ring and waiters over the shared external wake, registration pins and state-close withdrawal, endpoint release chain, cancellation reasons, worker lifecycle, OS-join retirement, and Group membership. |
| [Iteration-library implementation](iteration-library.md) | Read before changing `titan.iteration`; covers the `lua_next` stack ledger, generic erasure, the iterator tuple, and closed projections. |
| [Garbage-collection library implementation](gc-library.md) | Read before changing `titan.gc`; covers the weak-mode and finalizer stack ledgers, finalizer marking, the `gc.finalizable<\|value\|>` idiom, and collector control. |
| [Reflection-library implementation](standard-library-reflect.md) | Read before changing `titan.reflect`; covers metadata ownership, descriptor hydration, generated field accessors, native projections and default construction, value classification, function inspection, and owned C storage. |
| [JSON-library implementation](json-library.md) | Read before changing `titan.json`; covers the whole-document PEG, folds and budgets, locations, exact scalar conversion, reflection mapping, and the writer and resource policy. |
| [Protocol Buffers-library implementation](protobuf-library.md) | Read before changing `titan.protobuf`; covers reflective and generated nominal codecs, `TitanValue` fields, buffer growth, wire decoding, transfer collaboration, anonymous root messages, and proto3 schemas. |
| [Transfer-policy implementation](transfer-library.md) | Read before changing `titan.transfer`; covers packet classification and layout, raw-slot decode, module loading, closure snapshots, the scoped endpoint resource table, and manual resource handoff. |
| [SQLite-library implementation](sqlite3-library.md) | Read before changing `titan.sqlite3`; covers the native packet boundary, reservations and lifetime, connection transfer, cancellation, Lua-state close and abandoned worker waits, worker operations and errors, and owned row decoding with reflection. |
| [DNS and TCP implementation](libuv-networking.md) | Read before changing `titan.net`; covers DNS/TCP policy above UV/async: one-shot requests, dialing and listening, persistent and demand-driven reads, accept delivery, connection transfer, and close. |
| [TLS-library implementation](ssl-library.md) | Read before changing `titan.ssl`; covers TLS over `net.Connection`: pending-input snapshots, trust contexts, PEM decoding, BIO ownership, the duplex state machine, shutdown and EOF, Lua-state close, transfer, and OpenSSL build modes. |
| [URL-library implementation](url-library.md) | Read before changing `titan.url`; covers URL parsing and normalization, stored Relabel PEGs, labeled failure tuples, and request-component boundaries. |
| [HTTP-library implementation](http-library.md) | Read before changing `titan.http`; covers the llhttp callback bridge and pausing, client pooling and abandoned-body draining, upgrade and rejection, framing, server Tasks, serial keep-alive and idle timeouts, and Exchange transfer. |
| [WebSocket-library implementation](websocket-library.md) | Read before changing `titan.websocket`; covers opening and HTTP upgrade handoff, bounded framing and UTF-8, control priority and fairness, operation and terminal lifetimes, connection transfer, and verification. |
| [Lua interop internals](lua-interop-internals.md) | Read before changing Lua/Titan boundaries; covers the two Lua-stack entries, dynamic conversion of records, Arrays, unions and Interfaces, module metatables, the registry footprint, loading paths, and safety. |
| [Foreign-function implementation](foreign-functions.md) | Read before changing source C functions; covers the parser/AST, the raw-C checking context, source collaboration and image bindings, exact sequencing, `.titan.h` planning, and stdlib foreign callbacks. |
| [FFI internals](ffi-internals.md) | Read before changing `foreign import`; covers header preprocessing and parsing, semantic `file`/`search`/`origin` header identities and stat precision, TypeList extraction, `Type.C*`, `titan/ffi.h` bridges, checker rules, C calls, casts, arrays and fields, owned objects, and platform failure modes. |
| [C FFI declarations and expressions](c-ffi-expressions.md) | Read before changing target-validated C checks; covers tag identity, declarators, the arithmetic profile, probe caching, speculative batched acceptance probes, object-pointer conversion, automatic/FAM allocation, aggregate setjmp spills, operators, macros, and enum carriers. |
| [Trusted Lua C API boundary](ffi-lua-api-followup.md) | Read before using the Lua C API from Titan; covers why it is not a public FFI feature, the trusted stdlib discipline, and the per-operation stack/root ledger. |
| [Native test runner](test-runner.md) | Read before changing `titanc --test` or `titan.test`; covers `--test-dir`/`--test-exclude` root discovery, case discovery from certified objects, the synthetic runner, execution state, harness flags, regression placement, the native aggregate and its parallel owner groups, per-file Busted partitions, portability, and packaging. |
| [Native source coverage](native-coverage.md) | Read before changing native coverage; covers markers and `#line` conversion, `.coverage` object separation, backend checks and flags, counter reset/dump, gcov/gcovr reporting, metric scope, and serial Make targets. |
| [Completion analysis](completion.md) | Read before changing completion; covers coordinate-preserving source transforms, lexical and member candidates, detached saved descriptors, and private preparation. |
| [Driver and toolchain](driver.md) | Read before changing module lookup, loaders, the language-server compiler API and cache adapters, C compilation and linking, the parallel job scheduler and GNU Make jobserver client, native CLI switches, `titanc`, or `titan-runtime/`; includes the optional compiler-I/O `run_batch` capability, probe batches, cross-platform `luv` worker transport, and flag/environment references. |
| [Output-directory routing](output-directory.md) | Read before changing `-o`/`--output` or `--exe`; covers source-relative artifact locations, `native_output`/`program_output` mapping, `.native` and `.titan-links` directories, headers and temporary files, coverage paths, and validation. |
| [Experimental Windows build](windows-build.md) | Read before changing Windows support; covers the controlled Lua DLL and SDKs, native build parallelism, UTF-8 relocation and loading, the loader boundary, launchers, DLL publication, NTFS tests and their content-refresh ownership, coverage, and experimental limits. |
| [Build and installation responsibilities](build-script-audit.md) | Read before changing Make or LuaRocks; covers Lua and native dependency preparation, delegating stdlib and native-test module graphs to `titanc --incremental`, the Make job pool and guarded `titanc` recipes, install and publish targets, the private bootstrap, the LuaRocks install pass, and checks. |
| [Object-backed source modules](incremental-compilation.md) | Read before changing `--incremental` or `-c`; covers `.titan.source` envelope schemas and certificates, configuration/preamble/toolchain digests, own-source content and folder membership, semantic C-header revalidation, producer self digests, contextual owners and bindings, `certify_local`/`verdict`/`restore_source_object` ordering, `-v` miss codes, split-part checks via the primary record's `parts` list, LTO objects, and headers without an AST. |
| [Compiler-owned build coordinator](build-coordinator.md) | Read before changing `build.lua`, `build_worker.lua`, `linkcertificate.lua`, `nativeinputs.lua`, or `testroots.lua`; covers `.titan-build.lock` output coordination, closure planning and lexical import scanning, metadata-only hits and early cutoff, the `titan-build-worker-v1` control protocol and orphan lifetime, the single job-slot ledger, staged publication, `--c-source` nodes, final-link certificates, and `--test-dir` discovery. |
| [Folder modules](folder-modules.md) | Read before changing folder modules; covers resolver order and blocked contributors, single-AST assembly, one checker and code-generation pass, output and program paths, and stdlib ensembles. |
| [Multi-module libraries](multi-module-libraries.md) | Read before changing provider bundles; covers provider prefix selection, candidate search and claims, canonical runtime imports, shims and validated publication, and the canonical stdlib root list and image. |
| [Static compiled modules](static-compiled-modules.md) | Read before changing archive providers; covers the metadata section and payload, bounded container readers, target selection, import paths, native composition, three-way validation, the job-budgeted provider link pipeline, and publication. |
| [Selective binary dependency verification](binary-compatibility.md) | Read before changing provider compatibility; covers the compatibility projection, consumer usage, constant and closed-union proofs, generated exports and runtime verification, and provider-owned slots. |
| [Archived issue benchmarks](benchmark-archives.md) | Index of issue benchmark archives published as GitHub pre-release ZIPs, permalinks to retired evidence chapters, and archive verification. |

## Upgrading Lua

The pinned-Lua upgrade procedure is in
[codegen-overview](codegen-overview.md#upgrading-the-pinned-lua).

## Known limitations and quirks

Each row links the chapter section that documents the limitation.

| Where | Limitation / quirk |
| --- | --- |
| [AST and typedecl](ast-typedecl.md#the-cost-of-adding-a-node-or-type) | No compiler-enforced exhaustiveness: a missing visitor handler crashes on first contact, and some coder chains (`codeassignment`, `codefuncdec`) have no terminal error. Decorations are unvalidated, and post-checker ASTs are self-referential (`TableFormatLevel` hazard). |
| [Lexer and parser](lexer-parser.md#non-reentrancy) | The parser is non-reentrant: `parser.parse` asserts that no parse is active. `goto` and `finally` are reserved without surface productions. |
| [The type checker](checker.md#non-fallthrough-analysis) | Statements after a proven non-fallthrough statement are never checked. A local re-declared in the same block silently overwrites the earlier one. [Process-global state](checker.md#process-global-state) must be reset between checks. |
| [Code generator: overview](codegen-overview.md#compiled-module-abi) | Generated nominal codecs are ABI that no load-time check covers; every provider must be built against one SDK. Only `titan.protobuf`'s own handoff entry is type-checked, once at initialization, so a caller compiled against another handoff signature is not re-checked on each call and relies on the same one-SDK rule. A missing template variable aborts with an internal compiler error. |
| [Variadic parameters](variadic-parameters.md#gc-discipline-descriptor-pointers-and-untraced-payloads) | `...` is not first-class (no capture, storage, or escape); counts are capped at `TITAN_VARARG_MAX = 200`; `...[i]` raises out of range. Descriptor payloads are untraced, so elements need independent roots. |
| [Values and the GC](values-and-gc.md#gc-discipline-the-invariants) | Under the generational collector, a missing barrier or an unanchored fresh object is a reproducible use-after-free. |
| [Dense Arrays](dense-arrays.md#failure-and-performance-boundaries) | Debug-library or C API code can corrupt the private backing/proxy cycle, writer, or `lenhint`; Titan adds no validation. `rawget`/`rawset`/`rawlen` reject Arrays; stock `table.*` works through proxy metamethods. |
| [Closure adjustment wrappers](closure-adjustment-wrappers.md#runtime-eligibility-and-fallback) | Every realized wrapper is a fresh object, not identical to its source; non-Titan callables and closures at `MAXUPVAL` fall back to generic dispatch. |
| [Error handling](error-handling.md#setjmp-sensitive-localparameter-spills) | `finally` (also from `defer`) rejects `return` and escaping `break`; only `raise` overrides pending control flow. Volatile scalar recovery homes are a GCC/Clang guarantee, not ISO C; whole-program LTO exposing Lua's error machinery needs requalification. |
| [C FFI declarations and expressions](c-ffi-expressions.md#longjmp-safe-aggregate-spills) | Untracked raw aliases and asynchronous C writes are outside the aggregate spill guarantee. |
| [Coroutines](coroutines.md#stacks-and-backends) | The raw `mco_coro *` surface is private to `titan/coroutine.titan`; all translation units must share one sanitizer configuration; Binaryen Asyncify is unsupported; the Fiber backend is untested on Linux. |
| [Coroutines: unwinding](coroutines.md#unwinding-an-abandoned-coroutine) | Unwinding relies on the structured-entry invariant; C code that violates it makes the unwind abort the process. It skips foreign C frames and the finallies of providers compiled without the protocol, and a Lua `coroutine.close()` of a Titan coroutine's own thread skips its Titan finallies. Cleanup runs in a finalizer and cannot yield or await. The Fiber backend's recorded stack bounds are unvalidated. |
| [Async runtime: Lua-state close](libuv-runtime.md#lua-state-close-of-an-unretired-runtime) | State close withdraws parked waits by unwinding each suspended Task; closure-registered `unregister` functions then run inside a finalizer, must not yield, and may see newer objects already finalized. Cleanup cannot await, start a Task, or create a Runtime, so graceful protocol shutdown must happen before the close. |
| [Filesystem library: Lua-state close](filesystem-library.md#lua-state-close) | A File whose read, write or flush request a Lua-state close abandoned in flight keeps its descriptor open until process exit, because a worker may still use that descriptor number. |
| [Transfer policy](transfer-library.md#packet-scoped-resource-table-titan_transfer_resource_table) | The packet resource table adds no cycle collection: channels kept alive only by queued receiver attachments stay alive until the application closes a reachable receiver. |
| [Transfer policy](transfer-library.md#registration-attachment-and-claim) | A registered-resource decode context kept past its decode raises once the frame is idle, but use during a later decode that reuses the pooled frame is not detected and can claim from that packet. |
| [Lua interop internals](lua-interop-internals.md#safety-summary) | Container boundaries validate only the outer representation; Lua can mutate Maps and Arrays, so typed reads apply strict guards. Debug or C code can break private user-value, upvalue, and metatable invariants. |
| [Type relations and boundary plans](type-relations-and-boundaries.md#failure-contract-and-ffi-boundary) | Raw C pointers are outside gradual safety: they box as untyped light userdata, and a written `value as` raw-pointer cast is an unchecked reinterpretation. |
| [Generics](generics.md#design-and-safety-invariants) | Generic storage is transient and shallow: only the outer skeleton is checked before use, with no deep homogeneous heap invariant and no monomorphization. |
| [Const values](const-values.md#array-relations-and-linear-use-analysis) | `array_freeze` copies unless `checker/linear.lua` proves one of two narrow last-reference patterns (a builder local or fresh top-level returns). |
| [FFI internals](ffi-internals.md#platform-constraints-and-failure-modes) | Compile-time POSIX preprocessing dependency; headers outside the supported GNU/Clang subset can fail; some preprocessor failures raise raw Lua errors; function-like macros are invisible except through `titan/ffi.h` bridges; the C99 grammar is non-reentrant. |
| [String library](string-library.md#match-records-and-result-projection) | The convenience `matches` closure deliberately lets a nil first capture terminate a generic `for`. |
| [LPegLabel embedding](lpeglabel-embedding.md#construction-accounting-and-string-labels) | `behind` checks only the projected tree size; the engine alone enforces the capture-free, fixed-length, 255-byte look-behind rule. |
| [Driver and toolchain](driver.md#module-names-and-the-search-paths) | Synchronous `Sync` stat precision is coarse, so C headers are read and hashed once per validation pass rather than trusting mtime alone (with a same-size/same-coarse-second read-race residual under `Sync`); LuaFileSystem exposes no useful Windows file identities; `dlerror` reports only the last load attempt; compiler and flag strings use a small shell-word parser. |
| [Driver and toolchain](driver.md#gnu-make-jobserver-participation) | A `titanc` recipe without `+` under GNU Make 4.4 compiles with one job; a valid inherited pipe jobserver off Linux (such as macOS's stock GNU Make 3.81) uses `titanc`'s local `--jobs`/`TITAN_JOBS` cap outside the parent pool (sharing the parent pool requires GNU Make >= 4.4's FIFO jobserver or Linux's private pipe reopen); Windows ignores parent jobservers; a SIGKILLed `titanc` cannot return the tokens it borrowed. |
| [Object-backed source modules](incremental-compilation.md#build-and-validation-ownership) and [Build coordinator](build-coordinator.md) | Whole-interface digests are conservative (source-private doc edits invalidate `.titan` importers; compiler Lua comments invalidate all objects); tool executables use self-description plus physical metadata rather than binary content hashing; the compiler installation and source/header inputs must stay stable during a build; final-link certificates hash linker-reported (or compiler-resolved) library files without rewalking newly added candidates in earlier `-L` directories; `.titan-build.lock` covers local filesystems only; `--test-dir` candidate lookup inherits the shared resolver's POSIX non-matching `stat`-error behavior. |
| [Multi-module libraries](multi-module-libraries.md#validated-publication-and-generated-shims) | Generated Lua shims select providers through Lua's `package.cpath`, not the Titan search path. |
| [Static compiled modules](static-compiled-modules.md#publication-and-installation) | Publication is recoverable within the process, not crash- or power-loss-atomic. |
| [Binary compatibility](binary-compatibility.md#generated-exports-and-runtime-verification) | Verification is a protocol between generated providers, not a sandbox for untrusted DSOs. |
| [Windows build](windows-build.md#windows-dll-publication) | Stale-shim retirement is not implemented on Windows. |
| [Build and installation responsibilities](build-script-audit.md#make-job-pool-and-titanc-recipes) | GNU Make before 4.2 (macOS's stock 3.81) cannot show `make -j1`, so without an explicit `TITAN_JOBS` its builds stay serial with one job per `titanc`; set `TITAN_JOBS` or put GNU Make 4.2 or later first on `PATH` for the four-job pool. |
| [Windows build](windows-build.md#test-ownership-and-keep-going) | The Windows native aggregate runs as one serial process; only Unix splits it into parallel owner groups. |
| [Native source coverage](native-coverage.md#direct-execution-and-reports) | Metrics cover Titan executable lines only, with no denominator exclusions; timing-sensitive paths can gain or lose hits between runs. |
| [HTTP library](http-library.md#bounded-opening-and-protocol-takeover) | Ordinary client response parsers have no header-byte limit; there is no pipelining API, and keep-alive serves one exchange at a time. |
| [WebSocket library](websocket-library.md#protocol-state-and-fairness) | No buffered-work fairness bound or starvation guarantee; fairness observations are Linux-only, and conformance runs only the Linux amd64 image. |
| [OS library](os-library.md#shell-stream-transfer) | On Windows a fresh shell pipe usually has a pending overlapped read, so live shell-pipe handoff is rejected; [close does not terminate](os-library.md#shell-process-stream) the shell's descendant processes. |
| [DNS and TCP](libuv-networking.md#connection-transfer-ownership) | Windows overlapped reads block connection handoff unless the reader is demand-driven; on Windows a freshly connected socket needs one yield before transfer. |
| [TLS library](ssl-library.md#contexts-and-trust) | No CA-directory parameter and no platform Keychain or native trust store; encrypted private keys are rejected. |

Some of these also surface in the [language reference](../language/index.md)
as user-visible behavior; the links above point at the implementation-side
cause.

## Repository map

| Path | What it is |
| --- | --- |
| `titanc` | The compiler CLI ([command line](driver.md#the-titanc-command-line)). |
| `titan-compiler/` | The compiler: `lexer`/`parser`, `ast`/`typedecl`, `checker.lua` and `checker/`, `types`, `symtab`, `coder.lua` and `coder/`, `driver`, the build and certification modules (`build`, `build_worker`, `incremental`, `depfile`, `linkcertificate`, `nativeinputs`, `testroots`, `version`), the C-FFI modules (`cdeclarator`, `cpreamble`, `csemantics`, `cprobe`), metadata and cache modules, and `util`. |
| `c-parser/` | The pure-Lua C preprocessor and C99 parser behind `foreign import`. |
| `titan/` | Standard-library sources: 26 `titan.*` roots linked into `titan.so`/`titan.a`; see the [root list and image](multi-module-libraries.md#reserved-titan-and-the-standard-library-image). |
| `titan-runtime/` | C runtime support: `titan.h`/`titan.c`, `minicoro.h`/`minicoro.c`, `transfer.h`, `ltitanlib.c`, the Windows `titan_winloader.h` and `titanc_windows.c`, and the SDK header `titan/ffi.h`; see [the runtime support library](driver.md#the-runtime-support-library-titan-runtime). |
| `out/` | Default repository output tree; see [output-directory routing](output-directory.md). |
| `spec/` | The Busted outer harness and native Titan standard-library suites; coder specs generate, compile, and run C. |
| `doc/` | This implementation manual, the [language reference](../language/index.md), and the [style guide](../style-guide.md). |

Start with [repository workflow](repository-workflow.md) for prerequisites,
isolated SDKs, profiles, and commands. [AGENTS.md](../../AGENTS.md) is the
compact agent routing and policy guide; the implementation chapters own the
operational and technical detail.
