# The Titan language

Titan is a statically-typed, ahead-of-time-compiled sister language to
[Lua](https://www.lua.org). Titan modules compile to native code that runs
inside the Lua runtime: Lua programs `require` them like any other module,
call their functions, and share data with them directly. Titan's syntax
and semantics are deliberately close to a subset of Lua — a Lua programmer
can read Titan on first sight — but every variable has a static type, and
the compiler uses those types to generate code that works on Lua values
at C speed, with none of the dynamic dispatch of the Lua VM.

```titan
-- sum.titan
function sum_list(xs: {integer}): integer
    local sum: integer = 0
    for i = 1, #xs do
        sum = sum + xs[i]
    end
    return sum
end

function sample(): {integer}
    return {1, 2, 3, 4}
end
```

```lua
-- Lua, with sum.so on the Titan path
require "titan"   -- installs Titan's package searcher
local m = require "sum"
print(m.sum_list(m.sample())) --> 10
```

This is the reference for the language as implemented by the Titan 0.6.0
prototype compiler in this repository. It replaces the old single-file
manual. For how the compiler itself works — including how each construct
is translated to C — see the
[implementation documentation](../implementation/index.md).

## Reading guide

For a runnable introduction, start with the [Titan quick tour](../quick-tour.md).
Before contributing application or standard-library code, read the
[style guide](../style-guide.md). Start with the
[design philosophy](philosophy.md) if you want to know *why* Titan is shaped
the way it is; after the tour, continue with the [type system](types.md) and
use the chapters below for the normative language reference.

| Chapter | Covers |
| --- | --- |
| [Native build profiles](build-profiles.md) | Production optimization defaults, isolated O0/no-LTO validation SDKs, the same `TITAN_BUILD_PROFILE` selecting the browser target's profile, `titanc` worker and native job slot bounds inside and outside GNU Make, `--c-parts` splitting of large modules, and the checkout's build and test parallelism settings. |
| [Installing Titan on Linux and macOS](installation.md) | Build and install steps, the `PREFIX` and `ROCKS_TREE` directories, upgrading from a pre-release build, what the installation contains (including the support module and the installer's SDK digest manifest), the optional browser prerequisites (Emscripten, Node 26+ with JSPI, Chrome), `make lua-browser` and `make browser-sdk` for `--target browser`, how Titan finds them, bundled libuv and OpenSSL, compilation job defaults, building the standard library during development, uninstalling, and cleaning. |
| [Installing and using Titan on Windows](windows-build.md) | Experimental CLANG64 installation, standalone LuaRocks configuration, the native `titanc.exe` compiler, DLL programs and `--exe` launcher paths, link staging directories, the SDK fallback's `PATH` lookup, packaging, cleanup, native test entrypoints, Busted workers, and build parallelism. |
| [Documentation comments](documentation-comments.md) | LDoc-style summaries and tags retained for editor hover and completion. |
| [Design philosophy and history](philosophy.md) | Why Titan exists, its core commitments, the project's history and design principles. |
| [The type system](types.md) | All Titan types; equality, symmetric non-transitive consistency, direct coercions, gradual views, callable adjustment, the normative boundary matrix, inference, and `value`. |
| [Const values](const-values.md) | Const locals and module variables, runtime initializer dependencies, nil initialization and owner-only assignment authority, const record and Interface fields, Interface snapshots, and const-qualified Arrays with explicit shallow-copy conversion. |
| [Generics](generics.md) | Explicit type parameters and Interface constraints, applied nominal types, local instantiation, rigid-body capabilities, constraint erasure, shallow run-time checks, eligible FFI arguments, and generic Tasks. |
| [Type aliases](type-aliases.md) | Transparent compile-time type names, preserved record/union static namespaces, visibility, nominal re-exports, and alias cycles. |
| [Interfaces](interfaces.md) | Nominal behavioral/data views, const field snapshots and method dispatch, structural satisfaction, wrapper conversions, compiler-witnessed dynamic discovery, options, casts, Lua interoperation, and separate compilation. |
| [Option types](option-types.md) | `T?`: nil-tolerant types — syntax, semantics, defaulting with `or`, and how `nil` flows through arrays, maps, and the Lua boundary. |
| [Expressions](expressions.md) | Literals and escapes, operators and precedence, Lua-faithful arithmetic, concatenation, `and`/`or`, explicit casts with `as`, non-raising type tests with `is`, constructors, calls. |
| [Statements](statements.md) | Declarations and inference, assignment and multiple assignment, control flow, the numeric `for`, `defer`, `return`. |
| [Defer](defer.md) | `defer <statement>` cleanup, scoping, LIFO order, and interaction with return, break, raise, and catch. |
| [Functions](functions.md) | Declarations, argument adjustment, argument reachability during a call, multiple return values, visibility, functions as values, and the `main` convention for standalone programs. |
| [Named arguments](named-arguments.md) | Declaration-based `f { name = value }` and method-call syntax, omissions, evaluation order, record construction, direct C prototype names, and Lua's positional-only boundary. |
| [Anonymous functions and closures](closures.md) | Lambda expressions, contextual fixed/bare-variadic input and result inference, explicit `: ()`, inline immediate calls with finite/open results, lexical capture of enclosing locals, cross-state capture snapshots, fresh-value-per-evaluation semantics, and bound method references `obj:method`. |
| [Closure adjustment wrappers](closure-adjustment-wrappers.md) | Directional callable actions, missing nil results, conditional target-wrapper realization and fresh identity, source Lua behavior, strict/generic fallback, `as`/`is`, and limits. |
| [Variadic parameters](variadic-parameters.md) | The trailing `...: t` parameter, `#...`, the raising `...[e]` index, spreading `...` into calls, returns, and positional Array/integer-Map constructors, slot-driven adjust-up, checked C-scalar boxing into `value` varargs, variadic functions as values, and the limits and bans. |
| [Flexible returns](flexible-returns.md) | Runtime-sized homogeneous result tails, finite option projection, open sinks, contextual calls through `value`, surplus adjustment, and directional callable adjustment. |
| [Spread expressions](spread-expressions.md) | Tail-only expansion of whole or closed-range Array, integer-Map, and variadic subjects; exact subject rules, once-only evaluation, finite optional projections, open sinks, metamethods, and capacity limits. |
| [Native storage in records and unions](nominal-storage.md) | Exact foreign values, embedded C objects, borrowed interior pointers, shallow constness, and fresh buffers sharing their nominal owner. |
| [Records](records.md) | Nominal record types, record-call shorthand, overridable constructors, fields, methods, record functions, and records as seen from Lua. |
| [Unions](unions.md) | Nominal tagged unions with named payload parts, positional and named constructors and case bindings, full-block `when` arms, optional coverage with closed-union control-flow proof, and Lua visibility. |
| [Arrays and maps](arrays-maps.md) | Mutable and const-qualified positive-only, holed Arrays with deterministic highest-present length and distinct canonical Lua userdata tags; ordinary Maps, positional integer-Map construction, metamethod-aware indexing/equality/length and initializer exposure, conversions, and performance. |
| [Modules](modules.md) | Logical modules, `import`, visibility, module-variable initializer dependencies (stored callables versus explicit/implicit call exposure) and declaration-order execution, initialization blocks, and the compilation model (shared libraries, executables, `--print-root`, `titanc` build output with its progress, `-q` quiet, and `-v` verbose modes, the Titan path with `;;`, `!`, and the run-time SDK fallback, and loading compiled modules from Lua through Titan's package searcher). |
| [Visibility through explicit source imports](source-import-visibility.md) | Explicit `.titan` source imports over local declarations, direct-only Titan permission, canonical logical identity, required-source lookup, normalized use-driven C declaration origins, and the public-only ordinary-import/binary/Lua boundary. |
| [Multi-module libraries](multi-module-libraries.md) | Separating logical modules from physical providers: common-prefix library output, prefix lookup, `require` through Titan's package searcher, the reserved `titan` support name, and the combined standard library. |
| [Static compiled modules](static-compiled-modules.md) | Self-describing `.a` providers, paired `.so`/`.a` outputs, default and `--static` resolution, native composition, and bundled/system OpenSSL final-link behavior. |
| [Replacing shared-library dependencies](binary-compatibility.md) | Per-consumer load-time compatibility, copied native provider selection, required erased signatures and public nominal shapes, private storage changes and construction requirements, and union control-flow dependencies. |
| [Incremental and separate compilation](incremental-compilation.md) | Semantic object, `--c-source`, and final-link certification, compiler-owned parallel module scheduling, certified `-c --incremental` roots, `--print-c-objects`, the persistent digest cache and installed SDK digests, source versus output path spellings, reserved output names, verbose hit/miss diagnostics, and single-invocation Make integration. |
| [Output directories](output-directory.md) | `-o/--output` directory creation, `--exe` executable paths, `-I`/`-D`/`-L`/`-l`/`--cflag`/`--ldflag`/`--c-source`/`--print-c-objects` switches, reserved generated-C names and upgrading older (including moved) output trees, `.titan/`, `.native/`, and `.titan-links/` contents, the `.titan-target` one-target marker, `.titan-build.lock` coordination, coverage, and platform output layouts. |
| [Folder modules](folder-modules.md) | Splitting one logical module across a canonical main and immediate contributors: shared scope, deterministic order, lookup privacy, initialization, and artifacts. |
| [Target source selection](target-source-selection.md) | `name.<label>.titan` variants for `linux`, `darwin`, `windows`, `browser`, and the umbrella `native`: reserved spellings, per-target selection with absence-only fallback, target-only files, precedence, folder composition and the initializer rule, source imports, `-T`/`--target` and `TITAN_TARGET`, logical artifact names, incremental reuse, test roots, and editor behavior. |
| [Compiling for the browser target](browser-target.md) | Linux/macOS browser builds, Emscripten 6.0.13 and Node 26+, JSPI-capable engines, browser Lua/SDK installation, isolated output roots, production/validation profiles, three-file images and archive libraries, direct Emscripten C imports and helpers for unsupported C operations, enforced Wasm body/image byte bounds with source-attributed diagnostics, promise-based loader entry and terminal completion, calls queued during a drive, `callTask` Task-form calls with `AbortSignal`, the exit latch and `exited` completion, disposal that lets Task cleanup finish, admission around synchronous C callbacks, copied binary C stdio without a filesystem or shell, C stdin errors, per-instance environment snapshots, request-based input and output with sink/end-hook completion and declared backings, source-mapped traces, the browser standard library and the native-only modules it omits, shared codec/JSON nesting policies, and the conservative browser C-call limit. |
| [Browser Wasm-EH longjmp contract](browser-target.md#wasm-eh-longjmp-contract) | Consistent legacy Wasm-EH in Lua/SDK/objects/links, ambient compiler-flag isolation, protected calls across JSPI transfers, stale-record rebuilds, and fatal engine traps. |
| [JavaScript bindings](standard-library-browser.md) | Browser-only `titan.browser`: `BrowserValue` runtime-type marshalling (`is_nil`, `is_boolean`, `is_integer`, `is_float`, `is_string`, `is_bytes`, `is_handle`, `is_callable`), `BrowserHandle:call`, pinned callables and shared captures, `BrowserError`, `BrowserRequest` (`start`/`listen`), the reserved timer, driver, stdin/stdout/stderr and declared-stdio SDK bindings, the low-level driver interface (`is_owner`, `drive_begin`, `drive_end`, `relinquish` and its `RELINQUISH_` statuses, `deliver`, `wake`, `main_failed`), synchronous C callbacks (`BrowserPin`, `pin`, `titan_browser_call_sync`, the html5 click counter), and close-time invalidation. |
| [Lua interoperability](lua-interop.md) | Using Titan from Lua and Lua values in Titan: what crosses the boundary, what each type looks like on the other side, and where the run-time checks happen. |
| [Error handling](error-handling.md) | The run-time error model: what raises errors, error messages, `raise` (also with a saved trace), `catch`, `pcall`, `titan.backtrace()`, and the option-type idiom for recoverable failures. |
| [Coroutines](coroutines.md) | The `coroutine` standard module (`import "coroutine"` from Titan, `require "titan.coroutine"` from Lua): stackful asymmetric coroutines, tagged nested yield, error injection, explicit non-raising transfer outcomes with owned traces, current coroutine identity, status, Lua interop, and unwinding of abandoned coroutines (`defer`, generic-`for` close functions, and Lua `<close>` run at collection and state close), cleanup that needs asynchronous I/O, and unwinding limits. |
| [Public libuv binding](standard-library-uv.md) | Event loops, handles, requests, streams, filesystem, processes, threads and synchronization (including direct C-callable lock entries and a cross-thread wake bridge), and utilities; exact signatures, native status, callbacks, ownership, loop abandonment at final state teardown, and API coverage. |
| [Asynchronous I/O and tasks](async-io.md) | Tasks, their status, errors, and cancellation; scheduling and driving a Runtime; adapting callbacks with `await`; persistent subscriptions; waits on other OS threads and retirement gates for Tasks that own native resources; coalescing cross-state receivers; bounded same-state channels and Reader/Writer adapters; terminal listeners and combinators; exact-token resume; resources and shutdown, including Lua-state close with an active Runtime; and the browser target's driver, entries, ownership, exit and disposal. |
| [Thread standard library](standard-library-thread.md) | Bounded cross-thread FIFO channels (`Sender`, `Receiver`) with nil-preserving iteration, transferable endpoints, and the state-close rule for blocked channel operations; standalone OS worker threads (`Thread`, `ThreadStatus`, `Error`) with `join()`, cooperative cancellation, finalized handles, and an `async.Task` proxy that becomes terminal only after the OS thread is joined and cancels its thread when its state closes; and bounded `Group` execution with first-error cancellation and explicit retry boundaries. |
| [I/O standard library](standard-library-io.md) | The seven `Reader`/`Writer`/`Closer` Interface combinations, standard-output `print`, and ownership-safe line iteration. |
| [Timer standard library](standard-library-timer.md) | Task delays, cooperative `yield`, recurring `Ticker` handles, dropped ticks, explicit close, and browser timing on JavaScript timers. |
| [Mathematical standard library](standard-library-math.md) | Typed C99 numeric operations, Lua 5.5-compatible xoshiro256** random sequences, and length-bounded numeric conversion. |
| [Filesystem standard library](standard-library-fs.md) | Binary file I/O, missing-aware metadata, canonical paths, path operations, Runtime-bound filesystem watchers, and closing open Files at Lua-state close. |
| [TCP networking standard library](standard-library-net.md) | Asynchronous DNS and TCP clients/servers, opt-in shared-port listeners, binary stream reads, pending-input snapshots and observers, libuv-ordered writes, shutdown, close, and cancellation. Opt-in demand-driven reads support Windows connection handoff after callback retirement. |
| [TLS standard library](standard-library-ssl.md) | Verified TLS 1.2+ clients and certificate-backed servers with optional port reuse, composed over high-level TCP with memory BIOs, explicit trust overrides, authenticated shutdown, duplex reads/writes, pending-input snapshots and observers, independent abort, and engine and context release at Lua-state close. |
| [URL standard library](standard-library-url.md) | Nonthrowing parsing and normalization of absolute HTTP(S)/WS(S) URLs or separate request components, with structured labeled errors and public component records. |
| [HTTP/1.1 standard library](standard-library-http.md) | Strict HTTP and HTTPS clients with Runtime-scoped connection pools and bounded asynchronous response draining, ordered duplicate-preserving headers, standalone URL-module integration, streaming response/request bodies, per-connection server Tasks, opt-in shared-port listeners, ownership-aware request-header idle deadlines for listener and adopted Exchange serving, and sequential keep-alive request processing without pipelining support. |
| [WebSocket messages](standard-library-websocket.md) | Direct Task-blocking ws/wss clients and HTTP handler upgrades, message framing, origin/subprotocol policy, controls, and owned session retirement. |
| [Filesystem paths](standard-library-path.md) | Native lexical path normalization, joining, splitting, names, extensions and Windows volumes. |
| [Operating-system standard library](standard-library-os.md) | Portable clocks and timestamps, ISO C calendars/locales, environment, parent stdio (terminal, pipe, file, or connected TCP with output shutdown), signals, graceful exit, configurable direct child processes, shell-command `popen` with merged output, and manual endpoint payload disposal. |
| [PEG standard library](standard-library-peg.md) | Typed parsing-expression constructors and combinators, labeled failure/recovery, captures and callback timing, anchored pattern matching and leftmost search, locale controls, and relabel source notation. |
| [String standard library](standard-library-string.md) | Binary byte operations, Lua-compatible formatting and packing, synchronous in-memory streams, and compiled byte-regex matching, capture iteration, splitting, and substitution. |
| [Lua states and loading standard library](standard-library-lua.md) | Independent states, native loader snapshots, canonical `transfer.TransferValue` copy/borrow policies over a separate carrier that moves no packet attachments, custom reconstruction, exclusive background execution and host-state close during it, two-phase `Receiver` bootstrap and cleanup, Reader input, and state cleanup; current-state loading, cooperative `require`, caches, and searchers. |
| [Iteration standard library](standard-library-iteration.md) | Lua-compatible Map traversal, corrected generic-for iterator tuples, and Array iteration that preserves inner nil elements. |
| [Garbage-collection standard library](standard-library-gc.md) | Weak Maps and ephemerons, collector actions and mode switches, byte counts, and Lua 5.5 tuning parameters. |
| [Testing Titan code](standard-library-test.md) | The `titan.test` API, native `titanc --test` case discovery, `--test-dir` and `--test-exclude` automatic root discovery, subtests and cleanup, filtering, timed output with owner and run totals, failure output, process statuses, and the repository's parallel owner-group runs. |
| [Native source coverage](native-coverage.md) | Compile-and-run executable-line coverage, automatic source selection, incremental coverage object and link certification, separate `.coverage` objects, optional LCOV/HTML/Cobertura reports, and serial repository coverage runs. |
| [Reflection standard library](standard-library-reflect.md) | Runtime inspection of 19 value kinds, public nominal descriptors, explicit type resolution, erased generic schemas, callable metadata, checked field access, lossless native projections, and default construction. |
| [JSON standard library](standard-library-json.md) | JSON encoding and typed reflection-directed decoding, record and union mappings, optional null preservation, Unicode/numbers, structured diagnostics, and configurable resource limits shared by native and browser targets. |
| [Protocol Buffers standard library](standard-library-protobuf.md) | Public record and union serialization through compiler-generated or reflective codecs, self-describing `value` and erased generic fields, native-buffer entries, anonymous field messages, native C fields, the shared nesting limit, and independent-state payloads. Standalone protobuf calls grant no packet-resource authority. |
| [Transfer policies](standard-library-transfer.md) | Canonical `TransferValue` copy/borrow policies; raw native message packets and guarded raw-slot decoding; packet-scoped endpoint attachment and claim; C-only disposal; the manual-handoff inventory; and destination Runtime ownership. |
| [SQLite standard library](standard-library-sqlite3.md) | Embedded SQLite with asynchronous native work, prepared statements, owned rows and cursors, reflection bindings and mapping, explicit transactions, cancellation-safe cleanup, and connection release at Lua-state close. |
| [The C FFI](ffi.md) | `foreign import`: binding C headers, `#pragma once` and guarded includes, the include-depth limit, ignored and diagnosed preprocessor directives, supported types, calling C functions, foreign values/calls in module initializers, ownership, allocation, explicit NUL-terminated and counted binary pointer-to-string copies, the unsafe-boundary rules, and limitations. |
| [Foreign functions](foreign-functions.md) | Exact C-ABI exports through regular imports, runtime provider selection and stable per-image bindings, local source callbacks, restricted raw-C bodies with their own grammar (C types without `foreign`), C99 operator results and C99 and contextual numeric literal typing, zeroed automatic locals, pointer identity, generated companion headers, and sequencing. |
| [C FFI declarations and expressions](c-ffi-expressions.md) | Named C tags, compiled-probe caching and manual clearing, host-validated pointer conversions, target-directed automatic/owned allocation (including flexible tails), C storage after a caught error, typed object-macro values, identifier-macro aliases such as `stdout`, macro-projected fields, and target-correct C operators including C99 typing of literal operands. |
| [Grammar](grammar.md) | The complete lexical and syntactic grammar, including the separate grammar of foreign function bodies. |

## Status and limitations

Titan is a working prototype, version 0.6.0. The language documented here is
implemented and covered by the compiler's test suite. Its boundaries are
mostly missing features, plus a handful of constructs the compiler rejects
with a clean error; each links to the chapter that documents it in full.

Interfaces are part of the compiled-module ABI. A record
or union satisfies an Interface structurally at a statically known conversion
site, but the conversion constructs a fresh wrapper; it is not subtyping or
gradual consistency and does not lift through containers or functions. Dynamic
boundaries accept an existing exact wrapper or a bare full userdata whose
metatable advertises a pair witnessed by compiled conversion code. Lua and
`value` do not structurally search methods, and an unwitnessed record or union
remains rejected.

### First-class functions

* **Functions are first-class values.** A function name — a top-level
  function, a `local` function, an imported module's function, or a record
  static like `Rec.new` — used as a value yields a stable function value,
  and function types like `function (integer): (integer)` are accepted in every
  type position. Function values can be stored in locals, parameters,
  record fields, arrays and maps, passed, returned, and called. Exact
  Titan-to-Titan calls take a zero-overhead native path. A statically known
  non-exact callable edge conditionally realizes a fresh target-tagged wrapper;
  when realization is ineligible, branded Titan closures retain the strict
  generic path and non-Titan Lua callables retain ordinary Lua dispatch with
  dynamic result conversion
  ([functions](functions.md#functions-as-values),
  [closure adjustment wrappers](closure-adjustment-wrappers.md),
  [type system](types.md#function-types)). This also means Titan can
  **call a Lua function directly** — passing a Lua closure to a
  function-typed parameter and calling it
  ([Lua interop](lua-interop.md#calling-lua-from-titan)).
* **Anonymous functions and closures.** A `function (...) ... end`
  expression evaluates to a fresh function value, and it **closes over**
  the enclosing function's locals and parameters — reading them, and
  mutating them through a shared box when it assigns to them. Omitted lambda
  fixed-parameter and bare-variadic input types come from the expected function
  type. The complete result shape comes from an explicit annotation or that
  same expected type—never from the body—and defaults to zero results without
  either; explicit `: ()` fixes zero results even when context is available
  ([closures](closures.md)).
* **Bound instance methods are values too.** `obj:method` with no argument
  list is a function value that has the method's type with the implicit
  `self` removed, bound to the receiver — so a method *can* now be taken
  as a value ([closures](closures.md#bound-method-references),
  [records](records.md#methods)).
* **What is still not first-class.** Foreign/FFI functions are not Titan
  function values: a C function can be called by name or converted to a
  compatible C function pointer, but cannot be stored as a Titan function value
  ([the FFI chapter](ffi.md)).

### Smaller gaps and rough edges

* **Generic `for ... in` is available.** It iterates with a typed iterator
  tuple `(next, state, init, close)`, stops only on a nil first result, and
  runs the close function on exhaustion, `break`, `return`, or errors
  ([statements](statements.md#the-generic-for--in)).
* **No `goto`.** The word `goto` and label syntax are reserved/recognized
  but still have no statement form, so using them is a syntax error.
  `break` *is* supported (and a loop can also be exited with `return`)
  ([statements](statements.md#break-no-goto)).
* **Union variants are not first-class types.** Variants may carry several
  named payload parts, and construction and matching both accept positional
  or named forms. A `case` need not be exhaustive; complete coverage of the
  statically known closed union can nevertheless prove that it does not fall
  through ([unions](unions.md)).

### The C FFI

* **The FFI imports real C types, fields, arrays and owned objects**, and
  is the one place Titan's safety guarantees end. Treat `foreign` calls, source
  `foreign function` bodies, and raw-pointer handoff as an explicit unsafe
  boundary, comparable to Rust's `unsafe`: Titan code that uses none of them is
  expected to be well-behaved, while the foreign code and its native callers
  uphold the pointer, lifetime, ownership, ABI, and threading contracts of the
  APIs involved. A C function can misuse memory and crash the process, and a
  Titan `string` handed to a C function that frees or stores it corrupts the
  heap. Titan neither contains arbitrary native behavior nor validates that a
  raw pointer is usable. Contextual C primitives
  are distinct from Titan scalars and can form portable public pointer,
  function-pointer, and owned graphs. Header-imported C types support local
  annotations and regular `as <type>` casts; an exportable header-dependent C
  graph may enter a public interface only when every consumer supplies the
  original compatible declarations, because ordinary imports inherit no
  headers. Nonexportable C forms stay private.
  C arrays are 0-based (`T[N]` bounds-checked, pointers unchecked, counted
  owned arrays dynamically checked), `#` works for static/count-owned arrays,
  and struct/union fields can be read and written. Direct local `.new()` /
  `.new_array(count)` calls select explicit automatic, borrowed, or GC-owned
  zeroed storage from their sink; `T.new(count)` supports one
  flexible-array-member object while FAM `new_array` remains unavailable.
  Restricted [foreign functions](foreign-functions.md) supply plain C callback
  entries without adapting ordinary Titan closures. Explicit C variadic calls
  are supported. Adopting externally allocated C pointers into Titan's
  collector is not supported. Target-directed
  allocation, named tag-only structures, contextual object-pointer casts, and
  target-correct C operators are described in
  [C FFI declarations and expressions](c-ffi-expressions.md); see also
  [the full FFI limitation list](ffi.md#current-limitations).

### Other

* **Error handling is intentionally small.** Titan has `raise` and
  `catch`, but errors are still plain Lua values plus an
  out-of-band traceback: there is no exception class hierarchy and no
  chaining/cause mechanism. A new error in a catch handler replaces the
  previous one ([error handling](error-handling.md)).
* **Titan ships a focused standard library.** It includes stackful
  `coroutine`; the libuv-backed `async` Task facade and `timer`; `io`
  Interfaces plus printing and line iteration;
  asynchronous `fs` and `net`; reusable `url` parsing; high-level `ssl` and
  `http` short imports;
  portable `os` helpers, direct child processes, and shell-process streams;
  typed PEG construction; byte-oriented string/regex operations; the
  `math`, `lua`, `iteration`, and `gc` modules,
  including explicit weak-map policy and table/userdata finalizer ownership;
  and native test infrastructure through `test`.
  Lua loads every standard module through its qualified `titan.*` name,
  leaving Lua's own standard modules unchanged.
* **The browser target is young.** `titanc --target browser` builds
  WebAssembly programs, tests, and libraries for web pages and web
  applications, with unified Titan/Lua tracebacks backed by `.wasm.map` (full
  file/line attribution on Chromium, Firefox, and Node; function-level reduced
  fidelity on WebKit and Safari), but its standard library currently provides
  the thirteen modules that need no libuv, [`async`](async-io.md#the-browser-target)
  with a browser driver, [`timer`](standard-library-timer.md#on-the-browser)
  on JavaScript timers, and typed
  [JavaScript bindings](standard-library-browser.md), without `io`,
  `os`, files, or networking
  ([browser target](browser-target.md#the-browser-standard-library)).

The [README roadmap](../../README.md) lists where the language is headed;
the [philosophy chapter](philosophy.md) explains the principles that order
that list.
