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
-- Lua
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
| [Design philosophy and history](philosophy.md) | Why Titan exists, its core commitments, the project's history and design principles. |
| [The type system](types.md) | All Titan types; equality, symmetric non-transitive consistency, direct coercions, gradual views, callable adjustment, the normative boundary matrix, inference, and `value`. |
| [Const values](const-values.md) | Const locals and module variables, nil initialization, const record and Interface fields, Interface snapshots, and const-qualified Arrays with explicit shallow-copy conversion. |
| [Generics](generics.md) | Explicit type parameters and Interface constraints, applied nominal types, local instantiation, rigid-body capabilities, constraint erasure, shallow run-time checks, eligible FFI arguments, and generic Tasks. |
| [Type aliases](type-aliases.md) | Transparent compile-time type names, preserved record/union static namespaces, visibility, nominal re-exports, and alias cycles. |
| [Interfaces](interfaces.md) | Nominal behavioral/data views, const field snapshots and method dispatch, structural satisfaction, wrapper conversions, compiler-witnessed dynamic discovery, options, casts, Lua interoperation, and separate compilation. |
| [Option types](option-types.md) | `T?`: nil-tolerant types — syntax, semantics, defaulting with `or`, and how `nil` flows through arrays, maps, and the Lua boundary. |
| [Expressions](expressions.md) | Literals and escapes, operators and precedence, Lua-faithful arithmetic, concatenation, `and`/`or`, explicit casts with `as`, non-raising type tests with `is`, constructors, calls. |
| [Statements](statements.md) | Declarations and inference, assignment and multiple assignment, control flow, the numeric `for`, `defer`, `return`. |
| [Defer](defer.md) | `defer <statement>` cleanup, scoping, LIFO order, and interaction with return, break, raise, and catch. |
| [Functions](functions.md) | Declarations, argument adjustment, multiple return values, visibility, functions as values, and the `main` convention for standalone programs. |
| [Named arguments](named-arguments.md) | Declaration-based `f { name = value }` and method-call syntax, omissions, evaluation order, record construction, direct C prototype names, and Lua's positional-only boundary. |
| [Anonymous functions and closures](closures.md) | Lambda expressions, contextual fixed/bare-variadic input and result inference, explicit `: ()`, inline immediate calls with finite/open results, lexical capture of enclosing locals, fresh-value-per-evaluation semantics, and bound method references `obj:method`. |
| [Closure adjustment wrappers](closure-adjustment-wrappers.md) | Directional callable actions, missing nil results, conditional target-wrapper realization and fresh identity, source Lua behavior, strict/generic fallback, `as`/`is`, and limits. |
| [Variadic parameters](variadic-parameters.md) | The trailing `...: t` parameter, `#...`, the raising `...[e]` index, spreading `...` into calls, returns, and positional Array/integer-Map constructors, slot-driven adjust-up, variadic functions as values, and the limits and bans. |
| [Flexible returns](flexible-returns.md) | Runtime-sized homogeneous result tails, finite option projection, open sinks, contextual calls through `value`, surplus adjustment, and directional callable adjustment. |
| [Spread expressions](spread-expressions.md) | Tail-only expansion of whole or closed-range Array, integer-Map, and variadic subjects; exact subject rules, once-only evaluation, finite optional projections, open sinks, metamethods, and capacity limits. |
| [Native storage in records and unions](nominal-storage.md) | Exact foreign values, embedded C objects, borrowed interior pointers, shallow constness, and fresh buffers sharing their nominal owner. |
| [Records](records.md) | Nominal record types, record-call shorthand, overridable constructors, fields, methods, record functions, and records as seen from Lua. |
| [Unions](unions.md) | Nominal tagged unions with named payload parts, positional and named constructors and case bindings, full-block `when` arms, optional coverage with closed-union control-flow proof, and Lua visibility. |
| [Arrays and maps](arrays-maps.md) | Mutable and const-qualified positive-only, holed Arrays with deterministic highest-present length and distinct canonical Lua userdata tags; ordinary Maps, positional integer-Map construction, metamethod-aware integer-Map length, conversions, and performance. |
| [Modules](modules.md) | Logical modules, `import`, visibility, module variables, initialization, and the compilation model (shared libraries, executables, search paths). |
| [Visibility through explicit source imports](source-import-visibility.md) | Explicit `.titan` source imports over local declarations, direct-only Titan permission, canonical logical identity, required-source lookup, normalized use-driven C declaration origins, and the public-only ordinary-import/binary/Lua boundary. |
| [Multi-module libraries](multi-module-libraries.md) | Separating logical modules from physical providers: common-prefix library output, prefix lookup, generated Lua loaders, and the combined standard library. |
| [Static compiled modules](static-compiled-modules.md) | Self-describing `.a` providers, paired `.so`/`.a` outputs, default and `--static` resolution, native composition, and bundled/system OpenSSL final-link behavior. |
| [Replacing shared-library dependencies](binary-compatibility.md) | Per-consumer load-time compatibility, required erased signatures and public nominal shapes, private storage changes, and union control-flow dependencies. |
| [Incremental and separate compilation](incremental-compilation.md) | Opt-in object reuse, compile-only outputs, source-first selection, source-private metadata, and Make-owned dependency invalidation. |
| [Folder modules](folder-modules.md) | Splitting one logical module across a canonical main and immediate contributors: shared scope, deterministic order, lookup privacy, initialization, and artifacts. |
| [Lua interoperability](lua-interop.md) | Using Titan from Lua and Lua values in Titan: what crosses the boundary, what each type looks like on the other side, and where the run-time checks happen. |
| [Error handling](error-handling.md) | The run-time error model: what raises errors, error messages, `pcall`, `titan.backtrace()`, and the option-type idiom for recoverable failures. |
| [Coroutines](coroutines.md) | The `coroutine` standard module (`import "coroutine"` from Titan, `require "titan.coroutine"` from Lua): stackful asymmetric coroutines, tagged nested yield, error injection, current coroutine identity, status, and Lua interop. |
| [Asynchronous I/O and tasks](async-io.md) | Nonblocking Tasks, structured terminal statuses and errors, blocking foreign calls through the libuv worker pool, closeable bounded FIFO channels and string Reader/Writer adapters, terminal listeners, token-guarded explicit suspension/resume, fixed-arity any/race/all/join combinators, loop driving, cancellation, and final libuv-handle cleanup. |
| [I/O standard library](standard-library-io.md) | The seven `Reader`/`Writer`/`Closer` Interface combinations, standard-output `print`, ownership-safe line iteration, and shell-command `popen` with merged output. |
| [Timer standard library](standard-library-timer.md) | Task delays, cooperative `yield`, recurring `Ticker` handles, dropped ticks, and explicit close. |
| [Mathematical standard library](standard-library-math.md) | Typed C99 numeric operations, Lua 5.5-compatible xoshiro256** random sequences, and length-bounded numeric conversion. |
| [Filesystem standard library](standard-library-fs.md) | Binary file I/O, missing-aware metadata, canonical paths, path operations, and Runtime-bound filesystem watchers. |
| [TCP networking standard library](standard-library-net.md) | Asynchronous DNS and TCP clients/servers, binary stream reads, libuv-ordered writes, shutdown, close, and cancellation. |
| [TLS standard library](standard-library-ssl.md) | Verified TLS 1.2+ clients and certificate-backed servers composed over high-level TCP with memory BIOs, explicit trust overrides, authenticated shutdown, and serialized connection operations. |
| [URL standard library](standard-library-url.md) | Nonthrowing parsing and normalization of absolute HTTP(S) URLs or separate request components, with structured labeled errors and public component records. |
| [HTTP/1.1 standard library](standard-library-http.md) | Strict HTTP and HTTPS clients, ordered duplicate-preserving headers, standalone URL-module integration, streaming response/request bodies, per-connection server Tasks, ownership-aware request-header idle deadlines, and sequential keep-alive request processing without pipelining support. |
| [Operating-system standard library](standard-library-os.md) | Portable clocks and timestamps, ISO C calendars/locales, plus environment, parent stdio, signals, graceful exit, and configurable direct child processes. |
| [PEG standard library](standard-library-peg.md) | Typed parsing-expression constructors and combinators, labeled failure/recovery, captures and callback timing, anchored pattern matching and leftmost search, locale controls, and relabel source notation. |
| [String standard library](standard-library-string.md) | Binary byte operations, Lua-compatible formatting and packing, synchronous in-memory streams, and compiled byte-regex matching, capture iteration, splitting, and substitution. |
| [Lua loading standard library](standard-library-lua.md) | Binary-safe chunk compilation, Reader and file loading, asynchronous Lua-source `require`, cache semantics, C/Titan loaders, and the custom-searcher policy. |
| [Iteration standard library](standard-library-iteration.md) | Lua-compatible Map traversal, corrected generic-for iterator tuples, and Array iteration that preserves inner nil elements. |
| [Garbage-collection standard library](standard-library-gc.md) | Weak Maps and ephemerons, collector actions and mode switches, byte counts, and Lua 5.5 tuning parameters. |
| [Testing Titan code](standard-library-test.md) | The `titan.test` API, native `titanc --test` discovery, subtests and cleanup, filtering, failure output, and process statuses. |
| [Reflection standard library](standard-library-reflect.md) | Runtime inspection of 19 value kinds, public nominal descriptors, explicit type resolution, erased generic schemas, callable metadata, and checked dynamic field access. |
| [JSON standard library](standard-library-json.md) | JSON encoding and typed reflection-directed decoding, record and union mappings, optional null preservation, Unicode/numbers, structured diagnostics, and resource limits. |
| [SQLite standard library](standard-library-sqlite3.md) | Embedded SQLite with asynchronous native work, prepared statements, owned rows and cursors, reflection bindings and mapping, explicit transactions, and cancellation-safe cleanup. |
| [The C FFI](ffi.md) | `foreign import`: binding C headers, supported types, calling C functions, ownership, allocation, and limitations. |
| [Foreign functions](foreign-functions.md) | Source-defined exact C-ABI entry points, the restricted raw-C body, pointer types, explicit source collaboration, generated companions, sequencing, and callback use. |
| [C FFI declarations and expressions](c-ffi-expressions.md) | Named C tags, compiled-probe caching and manual clearing, host-validated pointer conversions, target-directed automatic/owned allocation (including flexible tails), typed object-macro values, macro-projected fields, and target-correct C operators. |
| [Grammar](grammar.md) | The complete lexical and syntactic grammar. |

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
  is the one place Titan's safety guarantees end — a C function can misuse
  memory and crash the process, and a Titan `string` handed to a C
  function that frees or stores it corrupts the heap. Contextual C primitives
  are distinct from Titan scalars and can form portable public pointer,
  function-pointer, and owned graphs. Header-imported C types support local
  annotations and regular `as <type>` casts but cannot be exported.
  C arrays are 0-based (`T[N]` bounds-checked, pointers unchecked, counted
  owned arrays dynamically checked), `#` works for static/count-owned arrays,
  and struct/union fields can be read and written. Direct local `.new()` /
  `.new_array(count)` calls select explicit automatic, borrowed, or GC-owned
  zeroed storage from their sink; `T.new(count)` supports one
  flexible-array-member object while FAM `new_array` remains unavailable.
  Restricted [foreign functions](foreign-functions.md) supply plain C callback
  entries without adapting ordinary Titan closures. Explicit C variadic calls
  are supported and adopted lifetimes remain parked. Target-directed
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
  Interfaces plus printing, line iteration, and shell-process streams;
  asynchronous `fs` and `net`; reusable `url` parsing; high-level `ssl` and
  `http` short imports;
  portable `os` helpers and direct child processes;
  typed PEG construction; byte-oriented string/regex operations; the
  `math`, `lua`, `iteration`, and `gc` modules,
  including explicit weak-map policy and table/userdata finalizer ownership;
  and native test infrastructure through `test`.
  Lua loads every standard module through its qualified `titan.*` name,
  leaving Lua's own standard modules unchanged.

The [README roadmap](../../README.md) lists where the language is headed;
the [philosophy chapter](philosophy.md) explains the principles that order
that list.
