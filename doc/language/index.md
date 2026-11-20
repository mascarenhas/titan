# The Titan Programming Language

Titan is a statically typed, ahead-of-time-compiled sister language to
[Lua](https://www.lua.org). Its syntax and arithmetic are close to Lua, every
expression has a static type, and compiled modules run inside the Lua runtime:
Lua programs `require` Titan modules like any other module, call their
functions, and share values and the garbage collector directly.

Titan compiles to native executables, shared `.so`/`.dll` providers, and static
`.a` archives on Linux, macOS, and Windows, as well as WebAssembly modules for
the browser through Emscripten.

```titan
-- sum.titan
function sum_list(xs: {integer}): integer
  local sum = 0
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
require "titan"
local m = require "sum"
print(m.sum_list(m.sample())) --> 10
```

## How to read this book

- **New to Titan:** Start with [Chapter 1: A Tour of Titan](tour.md), then read
  Parts I and II sequentially to build a complete mental model of types,
  modules, concurrency, Lua interop, C FFI, and browser WebAssembly.
- **Writing idiomatic code:** Keep the [Style Guide](../style-guide.md) handy
  for everyday conventions.
- **Looking up APIs, flags, or syntax:** Jump directly to Part III (Standard
  Library Reference) or Part IV (Installation, `titanc` Toolchain, Grammar &
  Conversions, and Design Principles).
- **Working on the compiler or runtime:** See the
  [Implementation Documentation](../implementation/index.md).

## Table of contents

### Part I — Tutorial and the Core Language

| Ch. | Chapter | Summary |
| ---: | --- | --- |
| 1 | [A Tour of Titan](tour.md) | Runnable walkthrough of executables, containers, options, records, unions, cleanup, Lua modules, async tasks, threads, and native tests. |
| 2 | [Lexical Structure, Values, and Expressions](expressions.md) | Tokens, literals, basic scalar types, Lua-faithful arithmetic and comparisons, Option-aware `and`/`or`, concatenation, length, and `as`/`is`. |
| 3 | [Statements, Scope, and Control Flow](statements.md) | Lexical blocks, `local` and `const` bindings, assignment, `if` truthiness, `while`/`repeat`, numeric and generic `for`, `return`, and `break`. |
| 4 | [Functions, Arguments, and Results](functions.md) | Declarations, arity adjustment, optional `T?` parameters, named calls, multiple and flexible returns, variadics, spreads, and standalone `main`. |
| 5 | [First-Class Functions and Closures](closures.md) | Function types, functions as values, contextual lambda inference, lexical captures, bound methods, callable adjustment, and cross-state snapshots. |
| 6 | [Arrays, Maps, and Iteration](arrays-maps.md) | Distinct `{T}` Arrays and `{K: V}` Maps, 1-based indexing and holes, `const`/`const?` Array views, Map equality, and iteration. |
| 7 | [Records and Methods](records.md) | Nominal records, `Record(...)` shorthand and custom `new`, mutable/`const`/`local` fields, instance methods, static functions, and optional receivers. |
| 8 | [Tagged Unions and Pattern Matching](unions.md) | Closed nominal unions, positional and named payload parts, variant constructors, `case ... when ... else`, and non-fallthrough coverage analysis. |
| 9 | [Interfaces](interfaces.md) | Nominal behavioral views, `const` field snapshots, structural satisfaction at conversion sites, `io` interfaces in practice, and `is`/`as` downcasts. |
| 10 | [Generics](generics.md) | Type parameters `<\|T\|>` on records, unions, Interfaces, and functions, Interface constraints, local inference, erasure, and dynamic boundaries. |
| 11 | [Type Aliases, Options, and Dynamic `value`](types.md) | Transparent `type` aliases, `T?` auto-unwrapping and `?` bindings, checked dynamism with `value`, strict projections, and conversion boundaries. |
| 12 | [Errors and Resource Cleanup](error-handling.md) | Choosing options versus `raise`, lexical `defer` cleanup, `catch` with `error` and `traceback`, re-raising, and `titan.backtrace()`. |

### Part II — Modules, Concurrency, and Interoperability

| Ch. | Chapter | Summary |
| ---: | --- | --- |
| 13 | [Modules and Program Structure](modules.md) | Flat and folder modules, visibility, module initializers, standard short imports, target variants, `.titan` source imports, LDoc comments, and [LuaRocks module packaging](modules.md#packaging-and-distributing-modules-with-luarocks). |
| 14 | [Concurrency: Tasks, Channels, and Threads](concurrency.md) | Cooperative `async` Tasks, combinators, cancellation, same-state channels, multi-core OS threads, bounded MPMC channels, and stackful coroutines. |
| 15 | [Interoperating with Lua](lua-interop.md) | Requiring Titan modules from Lua, cross-boundary representations, dynamic conversions versus strict guards, calling Lua via `lua`, and multiple states. |
| 16 | [Calling C: The Foreign Function Interface](ffi.md) | Unsafe boundary rules, `foreign import`, C types, pointers, operators, casts, strings, automatic and `owned` storage, embedded C fields, and linking. |
| 17 | [Foreign Functions and C Callbacks](foreign-functions.md) | Exporting C-ABI functions (`foreign function`, `.titan.h`), writing `local foreign function` callbacks, the GC-free raw-C subset, and safe wrappers. |
| 18 | [WebAssembly and the Browser Target](browser-target.md) | First web page and Vite deployment, complete browser application, Browser SDK setup, `--target browser` outputs, loader API, and browser limits. |

### Part III — Standard Library Reference

Titan ships **27** standard modules (**26** native modules plus browser-only
`browser`; **21** modules are available on `--target browser`: 14 complete
shared modules, 6 browser-adapted subsets, and `browser`). Titan source imports
each module by its short name; Lua loads the same module via `titan.<name>`.

#### Strings, Parsing, Math, and Iteration

| Module | Titan `import` | Lua `require` | Targets | Purpose |
| --- | --- | --- | --- | --- |
| [string](standard-library-string.md) | `"string"` | `"titan.string"` | Native & Browser | Byte operations, formatting, binary packing, in-memory streams, and compiled byte regexes. |
| [peg](standard-library-peg.md) | `"peg"` | `"titan.peg"` | Native & Browser | Typed parsing expression grammars, Relabel source notation, captures, and labeled recovery. |
| [math](standard-library-math.md) | `"math"` | `"titan.math"` | Native & Browser | C99 math operations, Lua 5.5 xoshiro256** random numbers, and bounded numeric parsing. |
| [iteration](standard-library-iteration.md) | `"iteration"` | `"titan.iteration"` | Native & Browser | `pairs`, `next`, and hole-preserving `ipairs` iterators for Maps and Arrays. |

#### I/O, Filesystem, and Operating System

| Module | Titan `import` | Lua `require` | Targets | Purpose |
| --- | --- | --- | --- | --- |
| [io](standard-library-io.md) | `"io"` | `"titan.io"` | Native & Browser | Shared `Reader`/`Writer`/`Closer` Interfaces, `print`, and ownership-safe `lines` iteration. |
| [path](standard-library-path.md) | `"path"` | `"titan.path"` | Native & Browser | Lexical path joining, splitting, normalization, extensions, and Windows volumes. |
| [fs](standard-library-fs.md) | `"fs"` | `"titan.fs"` | Native only | Asynchronous binary files, metadata, directory operations, and filesystem watchers. |
| [os](standard-library-os.md) | `"os"` | `"titan.os"` | Native & Browser (subset) | Time/dates, environment, stdio streams, exit; native adds clocks, host queries, signals, and processes. |

#### Concurrency, Runtime, and Transfer

| Module | Titan `import` | Lua `require` | Targets | Purpose |
| --- | --- | --- | --- | --- |
| [async](async-io.md) | `"async"` | `"titan.async"` | Native & Browser (subset) | Cooperative Tasks, combinators, cancellation, channels, subscriptions, and runtime shutdown. |
| [timer](standard-library-timer.md) | `"timer"` | `"titan.timer"` | Native & Browser (subset) | One-shot `sleep` delays and recurring `Ticker` handles on libuv or JavaScript timers. |
| [thread](standard-library-thread.md) | `"thread"` | `"titan.thread"` | Native only | Isolated OS worker threads, bounded cross-thread MPMC channels, and `thread.Group`. |
| [coroutine](coroutines.md) | `"coroutine"` | `"titan.coroutine"` | Native & Browser | Stackful asymmetric coroutines, tagged yield, error injection, and unwind cleanup. |
| [transfer](standard-library-transfer.md) | `"transfer"` | `"titan.transfer"` | Native & Browser | Canonical `TransferValue` copy/borrow rules, cross-state packets, and manual resource handoff. |

#### Networking and Web

| Module | Titan `import` | Lua `require` | Targets | Purpose |
| --- | --- | --- | --- | --- |
| [url](standard-library-url.md) | `"url"` | `"titan.url"` | Native & Browser | Nonthrowing HTTP(S)/WS(S) URL parsing, normalization, and structured error positions. |
| [net](standard-library-net.md) | `"net"` | `"titan.net"` | Native only | Asynchronous DNS resolution, TCP clients and servers, and byte-stream connections. |
| [ssl](standard-library-ssl.md) | `"ssl"` | `"titan.ssl"` | Native only | Verified TLS 1.2+ clients and certificate-backed servers layered over TCP. |
| [http](standard-library-http.md) | `"http"` | `"titan.http"` | Native & Browser (subset) | HTTP/HTTPS client with headers and `RequestOptions`; native adds connection pools and HTTP/1.1 servers. |
| [websocket](standard-library-websocket.md) | `"websocket"` | `"titan.websocket"` | Native & Browser (subset) | WebSocket `ws`/`wss` clients and message framing; native adds HTTP server upgrades. |

#### Serialization, Databases, and Reflection

| Module | Titan `import` | Lua `require` | Targets | Purpose |
| --- | --- | --- | --- | --- |
| [json](standard-library-json.md) | `"json"` | `"titan.json"` | Native & Browser | JSON encoding, reflection-directed typed decoding, null policies, and structured diagnostics. |
| [protobuf](standard-library-protobuf.md) | `"protobuf"` | `"titan.protobuf"` | Native & Browser | Proto3 encoding/decoding for records and unions, portable codecs, and anonymous messages. |
| [sqlite3](standard-library-sqlite3.md) | `"sqlite3"` | `"titan.sqlite3"` | Native only | Asynchronous embedded SQLite connections, prepared statements, transactions, and record mapping. |
| [reflect](standard-library-reflect.md) | `"reflect"` | `"titan.reflect"` | Native & Browser | Runtime value inspection, nominal type descriptors, field access, and dynamic construction. |

#### Testing, Garbage Collection, and Host Bridges

| Module | Titan `import` | Lua `require` | Targets | Purpose |
| --- | --- | --- | --- | --- |
| [test](standard-library-test.md) | `"test"` | `"titan.test"` | Native & Browser | Native `test_*` discovery, assertions, subtests, scoped cleanup, skips, and filtering. |
| [gc](standard-library-gc.md) | `"gc"` | `"titan.gc"` | Native & Browser | Weak Maps, ephemerons, reachability finalizers, collector modes, and Lua 5.5 tuning. |
| [lua](standard-library-lua.md) | `"lua"` | `"titan.lua"` | Native & Browser (subset) | Loading Lua chunks, `require`, and isolated `lua.Lua` states; native adds `dofile` and `run_async`. |
| [browser](standard-library-browser.md) | `"browser"` | `"titan.browser"` | Browser only | Typed JavaScript handles, `BrowserValue` marshalling, async requests, and pinned callbacks. |
| [uv](standard-library-uv.md) | `"uv"` | `"titan.uv"` | Native only | Low-level public libuv binding for event loops, handles, requests, threads, and locks. |

### Part IV — Reference Appendices

| App. | Appendix | Summary |
| --- | --- | --- |
| A.1 | [Installing Titan on Linux and macOS](installation.md) | Default prefix setup, checkout and browser SDK builds, OpenSSL/Readline options, installed layout, and uninstalling. |
| A.2 | [Installing and Using Titan on Windows](windows-build.md) | Experimental MSYS2 CLANG64 build, Lua DLL and C helpers, DLL distribution, browser builds, and Windows notes. |
| B | [The `titanc` Toolchain, Linking, and Coverage](toolchain.md) | Complete CLI flags, environment variables, `-o` layout, `TITAN_PATH_0_6`, providers, DSO replacement, `--incremental`, profiles, and `--coverage`. |
| C | [Lexical, Conversion, and Grammar Reference](grammar.md) | Reserved and contextual words, member-name rules, operator precedence, conversion boundary matrix, and complete EBNF grammar. |
| D | [Design Principles and Lineage](philosophy.md) | The Lua performance bargain, Titan's five core design commitments, and the LabLua/Typed Lua/Pallene lineage. |
