# Titan agent guide

Titan is a statically typed sister language to Lua. The Lua-written compiler
translates each logical `.titan` module to C against the pinned Lua internals.
Start with the relevant documentation below before changing its contract;
read the matching chapters rather than loading the whole manual into context.

## Startup and working rules

Before writing, editing, or reviewing any `.titan` source, read
[`.agents/skills/titan-programmer/SKILL.md`](.agents/skills/titan-programmer/SKILL.md).
It is the mandatory Titan basics cartridge; do not reconstruct Titan from Lua,
TypeScript, Go, or C. Load every applicable peer cartridge as well:

| Work | Skill |
| --- | --- |
| Application repository, build layout, executable delivery | [titan-application](.agents/skills/titan-application/SKILL.md) |
| Native tests, fixtures, test-layer placement, filtering | [titan-tester](.agents/skills/titan-tester/SKILL.md) |
| Tasks, timers, cross-state Receivers, cancellation, libuv callbacks, native ownership | [titan-async](.agents/skills/titan-async/SKILL.md) |
| Cross-thread channels, thread handles, thread groups | [titan-thread](.agents/skills/titan-thread/SKILL.md) |
| URL, TCP, TLS, HTTP | [titan-networking](.agents/skills/titan-networking/SKILL.md) |
| WS/WSS messages, upgrades, controls, lifecycle, conformance | [titan-websocket](.agents/skills/titan-websocket/SKILL.md) |
| C imports, callbacks, Lua interop, `titan.lua` | [titan-ffi](.agents/skills/titan-ffi/SKILL.md) |
| PEG/relabel parsers and combinators | [titan-pegs](.agents/skills/titan-pegs/SKILL.md) |
| Runtime schemas, nominal descriptors, reflected access | [titan-reflect](.agents/skills/titan-reflect/SKILL.md) |
| JSON, null policy, typed mappings, diagnostics | [titan-json](.agents/skills/titan-json/SKILL.md) |
| Compiler completion and language-server completion integration | [titan-completion](.agents/skills/titan-completion/SKILL.md) |

For example, async networking behavior tests require programmer, tester, async,
and networking. The cartridges are the operational default; follow their links
into manuals, source, and focused tests for edge cases or contract changes.

When adding or changing a user-visible language feature, update **both** the
[language manual](doc/language/index.md) and
[implementation manual](doc/implementation/index.md), including their indexes,
in the same change. The paired [language](doc/language/variadic-parameters.md)
and [implementation](doc/implementation/variadic-parameters.md) variadic chapters
are the model. Documentation is part of done.

Much of Titan's architecture is intentional. Follow existing invariants for
routine gaps. If a solution appears to need identity tricks, symbolic/hard-link
dependencies, unusual indirection, or accumulating special cases, inspect the
design first and then ask the maintainer about the intended invariant before
adding a workaround.

Preserve concurrent checkout ownership. Use separate worktrees/source copies for
compiler fixtures and builds that share native Make outputs. Give concurrent
generated-code configurations distinct `--output` directories and incompatible
native inputs separate SDK prefixes. A different prefix alone does not isolate
build artifacts. Inspect checkout state before cleanup and remove only artifacts
owned by the current task.

## Find the implementation contract

The [implementation index](doc/implementation/index.md) contains the pipeline,
repository map, complete chapter catalogue, and known limitations. The
[language index](doc/language/index.md) is the normative syntax/API catalogue;
use the corresponding language chapter alongside an implementation change.
Read the [style guide](doc/style-guide.md) before application or stdlib work.

| Task | Read first |
| --- | --- |
| Add an AST node or type; audit visitors/decorations | [AST and typedecl](doc/implementation/ast-typedecl.md) |
| Syntax, tokens, precedence, labels, source locations | [Lexer and parser](doc/implementation/lexer-parser.md), [grammar](doc/language/grammar.md) |
| Checker staging, scopes, initialization frontiers, AST elaboration | [Checker](doc/implementation/checker.md) |
| Consistency, coercion, guards, casts/tests, callable/assignment plans | [Type relations and boundaries](doc/implementation/type-relations-and-boundaries.md), [language types](doc/language/types.md) |
| Generic inference, constraints, erasure, metadata | [Generics](doc/implementation/generics.md) |
| Const locals/fields/Arrays and initialization authority | [Const values](doc/implementation/const-values.md) |
| Record-call desugaring, `new` overrides, literal construction authority | [Record constructors](doc/implementation/record-constructors.md) |
| Transparent type aliases, owner namespaces, serialized `type_members` | [Type aliases](doc/implementation/type-aliases.md) |
| Interface field snapshots, method dispatch, structural satisfaction, wrapper conversions | [Interfaces](doc/implementation/interfaces.md) |
| Union constructors/payloads, `case` coverage, variant metadata and schema validation | [Unions](doc/implementation/unions.md) |
| Generated function entries/calling convention, closures/capture boxes, `_fn`, module `_init` | [Codegen overview](doc/implementation/codegen-overview.md) |
| Cross-state closure manifests, capture snapshots, fresh mutable cells, destination module loading | [Closure transfer metadata](doc/implementation/codegen-overview.md#cross-state-closure-transfer-metadata), [snapshot policy](doc/implementation/transfer-library.md#closure-snapshots); public [closure transfers](doc/language/closures.md#transferring-a-closure-between-lua-states) |
| Genuine Lua vs strict Titan calls, dynamic coercion, Lua-visible values and metatables | [Lua interop internals](doc/implementation/lua-interop-internals.md) |
| `TValue`/`Udata` representation, stack rooting, allocation anchoring, write barriers | [Values and GC](doc/implementation/values-and-gc.md) |
| Record/union traced UV and native payload, public prefixes, embedded C objects and tails | [Native nominal storage](doc/implementation/nominal-storage.md) |
| Arrays, proxy identity, length, Lua writes, strict reads | [Dense Arrays](doc/implementation/dense-arrays.md) |
| Operators, evaluation, control flow, Maps, generated constructs | [Codegen constructs](doc/implementation/codegen-constructs.md) |
| Function-type adjustment: target-tagged wrappers, native adapters, strict relays | [Closure adjustment wrappers](doc/implementation/closure-adjustment-wrappers.md) |
| Immediately called lambda inlining, logical frames, finite/open results, cleanup | [Immediate functions](doc/implementation/immediate-functions.md) |
| Named calls, declaration parameter names, omissions, source-order normalization | [Named arguments](doc/implementation/named-arguments.md) |
| Variadic input parameters, `...`, descriptor ABI, vararg scope and rooting | [Variadic parameters](doc/implementation/variadic-parameters.md) |
| Flexible result tails, finite/open result demand, contextual calls through `value` | [Flexible returns](doc/implementation/flexible-returns.md) |
| Array/integer-Map/vararg spread ranges, tail expansion, open-sink lowering | [Spread expressions](doc/implementation/spread-expressions.md) |
| `raise`/`catch`, traceback attribution, longjmp, cleanup | [Error handling](doc/implementation/error-handling.md), [defer](doc/implementation/defer.md) |
| Stackful coroutine transfer, minicoro, suspended roots | [Coroutines](doc/implementation/coroutines.md) |
| C-header preprocessing/type extraction, `foreign import`, `.ffi.h` pipeline | [FFI internals](doc/implementation/ffi-internals.md) |
| C casts/operators/macros/enums, target arithmetic, compile-probe result caching | [C FFI declarations and expressions](doc/implementation/c-ffi-expressions.md) |
| Public/local C-ABI functions, runtime-resolved raw imports, restricted foreign bodies, `.titan.h`, sequencing | [Foreign functions](doc/implementation/foreign-functions.md) |
| Trusted raw Lua C API: stack/root ledger, protected independent-state calls, native preload helpers, longjmp, audited allowlist | [Trusted Lua C API boundary](doc/implementation/ffi-lua-api-followup.md) |
| Module lookup, C compilation/linking, CLI flags, SDK/tool paths, language-server API | [Driver and toolchain](doc/implementation/driver.md) |
| Native loader/provider snapshots, canonical module selection, per-state Titan bindings, stable raw-function image bindings, ABI checks before initialization | [Module protocol](doc/implementation/codegen-overview.md#the-module-protocol), [dependency wiring](doc/implementation/codegen-overview.md#static-vs-dynamic-dependency-wiring), [runtime verification](doc/implementation/binary-compatibility.md#generated-exports-and-runtime-verification) |
| Generated files under `-o`/`--output`, source-relative layouts, incremental/coverage paths | [Output-directory routing](doc/implementation/output-directory.md), [output user guide](doc/language/output-directory.md) |
| Folder mains/contributors, declaration order, canonical module/output identity | [Folder modules](doc/implementation/folder-modules.md) |
| Explicit `.titan` imports: local visibility, trusted source provenance, inherited C headers | [Source-import visibility](doc/implementation/source-import-visibility.md) |
| Compile-only `-c`, incremental `.o` reuse, source-object metadata, Make-owned invalidation | [Incremental compilation](doc/implementation/incremental-compilation.md) |
| Prefix providers, multi-root `.so`/`.a` bundles, Lua shims, staged pair publication | [Multi-module libraries](doc/implementation/multi-module-libraries.md) |
| Archive/object metadata, ELF/Mach-O/COFF readers, target selection, static composition | [Static compiled modules](doc/implementation/static-compiled-modules.md) |
| Replacing a DSO: consumer-used signatures/public shapes and runtime verification | [Binary compatibility](doc/implementation/binary-compatibility.md) |
| Hover/doc comments, completion, long-lived semantic clients | [Documentation comments](doc/implementation/documentation-comments.md), [completion](doc/implementation/completion.md), [language-server API](doc/implementation/driver.md#language-server-compiler-api) |

Keep `driver.LANGUAGE_SERVER_API_VERSION` at **1 until the first public
release**. Generated-code ABI and persisted cache schemas are separate
contracts. Current version identities live in
[`titan-compiler/version.lua`](titan-compiler/version.lua); ABI changes require
a clean compiler/runtime/provider rebuild, without historical migration or
compatibility machinery unless explicitly requested.

## Standard-library work

Read [standard-library maintenance](doc/implementation/standard-library-maintenance.md)
for implementation ownership, direct APIs, precise types, and audited Lua/C
boundaries. Public behavior belongs in native Titan tests; compiler mechanics
belong in the corresponding compiler layer.

| Area | Implementation chapters |
| --- | --- |
| Native libuv owners/requests, callback lifetime, adding a binding or Task adapter | [Libuv extension guide](doc/implementation/libuv-extension-guide.md); [generic wait policy](doc/implementation/libuv-runtime.md) |
| Task scheduling, Completion waits, ResumeToken wakes, subscriptions, Runtime-close listeners, cancellation, shutdown, timers | [Async continuation runtime](doc/implementation/libuv-runtime.md); public [async](doc/language/async-io.md) and [timer](doc/language/standard-library-timer.md) contracts |
| Cross-state `TransferValue` policies, flat packets, closure snapshots, custom hooks, manual native resource handoff | [Transfer policy](doc/implementation/transfer-library.md); public [transfer policies](doc/language/standard-library-transfer.md) and [conversions](doc/language/async-io.md#transfer-values) |
| Lossy coalescing Receiver ownership, copied packets, borrowed send handles, two-phase bootstrap/cleanup | [Receiver ownership](doc/implementation/libuv-runtime.md#cross-state-receiver-ownership), [bootstrap and teardown](doc/implementation/lua-library.md#receiver-bootstrap-and-teardown); public [receivers](doc/language/async-io.md#cross-state-receivers) |
| Cross-thread channels, standalone Thread handles, bounded Group execution | [Thread library](doc/implementation/thread-library.md); public [thread](doc/language/standard-library-thread.md) contract |
| I/O Interfaces, printing, iteration, shell streams | [I/O library](doc/implementation/io-library.md) |
| Files, metadata, watchers, lexical paths | [Filesystem library](doc/implementation/filesystem-library.md), [path library](doc/implementation/standard-library-path.md) |
| Child processes, stdio, signals, graceful exit | [OS library](doc/implementation/os-library.md) |
| DNS/TCP, TLS, shared-port listener binds, URLs, HTTP pooling/framing/deadlines | [DNS/TCP request and stream adapters](doc/implementation/libuv-networking.md), [TLS](doc/implementation/ssl-library.md), [URL](doc/implementation/url-library.md), [HTTP](doc/implementation/http-library.md) |
| WebSocket framing, controls, byte/ownership handoff, retirement | [WebSocket library](doc/implementation/websocket-library.md) |
| PEG, relabel, private LPegLabel engine and payload | [LPegLabel embedding](doc/implementation/lpeglabel-embedding.md) |
| Byte strings, writers, regex, format/pack | [String library](doc/implementation/string-library.md) |
| Numeric functions, random, number parsing | [Math library](doc/implementation/math-library.md) |
| Independent Lua states, exclusive worker execution, native preload snapshots, source loading and `require` cache | [Lua-state and loading library](doc/implementation/lua-library.md); public [Lua states and loading](doc/language/standard-library-lua.md) contract |
| Map/Array iteration, weak Maps, finalizers, collector controls | [Iteration](doc/implementation/iteration-library.md), [GC library](doc/implementation/gc-library.md) |
| Runtime reflection, native projections/default construction, typed JSON mapping, asynchronous SQLite | [Reflection](doc/implementation/standard-library-reflect.md), [JSON](doc/implementation/json-library.md), [SQLite](doc/implementation/sqlite3-library.md) |
| Protocol Buffers encoding/decoding, proto3 schemas, anonymous messages, reflected native fields | [Protocol Buffers](doc/implementation/protobuf-library.md); public [protobuf API](doc/language/standard-library-protobuf.md) |
| Native case discovery, subtests, cleanup, reporting | [Test runner](doc/implementation/test-runner.md), public [test API](doc/language/standard-library-test.md) |

Only `titan.uv` owns libuv FFI; adapters use ordinary compiled public UV imports
and generic async waits/subscriptions. Do not reach private binding or scheduler
state with `uv.titan`/`async.titan`. Keep GC-bearing semantic state on traced
owners, and preserve native ownership until terminal callbacks and cleanup.

## Build, test, and delivery

Read the matching workflow before executing commands or changing build policy:

| Task | Read first |
| --- | --- |
| Bootstrap Lua/LuaRocks, choose SDK, build/install/package/uninstall | [Repository workflow](doc/implementation/repository-workflow.md), [build responsibilities](doc/implementation/build-script-audit.md) |
| Production vs validation inputs, prefix isolation, effective flags | [Build profiles](doc/language/build-profiles.md) |
| Test placement, shared helpers, fixture ownership, native aggregate | [Regression placement](doc/implementation/test-runner.md#regression-placement), [test-runner implementation](doc/implementation/test-runner.md), [repository workflow](doc/implementation/repository-workflow.md) |
| Linux/macOS lanes, sharding, caches, sanitizer diagnostics | [Continuous integration](doc/implementation/continuous-integration.md) |
| Native coverage, source attribution, separate coverage objects | [Native coverage implementation](doc/implementation/native-coverage.md), [coverage commands](doc/language/native-coverage.md) |
| Windows prerequisites, SDK, DLL providers/launchers, native tests | [Windows build](doc/implementation/windows-build.md), [Windows user guide](doc/language/windows-build.md) |

Use a prepared Lua **5.5.1** SDK and matching internal headers/archive. Ordinary
builds default to `production`; repository tests select `validation`.
`PREFIX` owns Lua/LuaRocks and `ROCKS_TREE` owns Titan's rock, SDK, and stdlib;
the supported layout currently sets them equal. Warm Lua/LuaRocks preparation
does not rebuild installed programs after native input changes.

For Unix verification, choose an absolute isolated prefix and put its `bin` on
`PATH`. Run from the repository root. The common entry points are:

```sh
make test                                           # prepare/reinstall and run the full mixed suite
make busted-test BUSTED_FILTER='parser'              # installed compiler snapshot, Busted only
TITAN_ROCKS_ROOT="$PREFIX" TITAN_PROBE_CACHE_DISABLE=1 busted --run=checkout spec/parser_spec.lua
make titan-stdlib-test                              # build and run the native aggregate
make titan-stdlib-test-run TITAN_FILTER='^ssl[.]tests[.]' # reuse its built executable
```

Default Busted and `luarocks test` use the installed compiler; the checkout
profile loads edited compiler Lua with the selected installed SDK. It does not
refresh runtime/providers. `luarocks test` does not build the rock; `make test`
reinstalls it. Filters for Busted and native Titan tests are independent.
Canonical full runs must start without ambient `ROCKS_TREE`, `TITAN_ROCKS_ROOT`,
`TITAN_EXTRA_CPPFLAGS`, or `TITAN_NO_LINE_DIRECTIVES`; clear Lua path overrides
for manual prefix-tool invocations too. See the workflow for focused overrides.

Treat shared runtime archives, providers, shims, and native dependencies as
Make-owned read-only inputs during compiler fixtures. Never broadly delete
`.a`, Lua shims, or authored C fixtures. Clean affected generated/native outputs
when changing tools, flags, profile, or OpenSSL mode, following documented
ownership boundaries. Serialize builds that share those outputs.

Linux push CI and local validation are separate evidence. Complete macOS
validation is a pre-merge gate; prefer the complete local VM run and record its
architecture. Hosted `macos.yml` is a manual fallback: dispatch only after an
explicit maintainer request for macOS CI; opening/updating a PR is insufficient.
Keep Windows source/output state separate from Unix, use `Makefile.win`, and
validate filesystem/SQLite/local watchers on NTFS. A VM boot or component check
is not complete platform validation.
