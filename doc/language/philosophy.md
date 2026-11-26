# Design principles and lineage

Titan is a statically typed, ahead-of-time-compiled sister language to
[Lua](https://www.lua.org). It shares Lua's syntax, values, and garbage
collector so that performance-sensitive parts of a Lua system—or complete
standalone programs and WebAssembly modules—can be written in a language that
remains recognizably Lua while compiling to native C speed.

## The Lua performance bargain

Lua programmers who chase speed end up writing a cramped dialect: caching
library functions in locals, replacing `table.insert` with `xs[#xs + 1] = v`,
and hand-unrolling `ipairs` into numeric loops. The language is clean and
expressive, yet users repeatedly trade clarity away for throughput.

There are two structural ways out of that trap:

1. **Build a tracing or method JIT for Lua.** LuaJIT demonstrates how fast a
   great JIT can be, but JIT compilers are expensive to maintain, lag behind
   language evolution, and create performance cliffs—code the JIT traces runs
   at near-C speed, while code that aborts a trace drops an order of magnitude
   with little warning.
2. **Pair Lua with a compiled system language.** This is the classic
   scripting-language bargain: use Lua for flexible glue and a statically
   typed compiled language for the hot code. Traditionally that second
   language is C through the Lua C API, which is stack-based, error-prone, and
   semantically distant from Lua—making the crossing worthwhile only for large
   subsystems.

Titan takes the second path and removes the friction from the boundary. Rather
than pairing Lua with C, Titan pairs Lua with a statically typed language
designed specifically for Lua's runtime and data model. Moving a function or a
module across the boundary requires no foreign marshalling layer, and calling
between Titan and Lua is cheap enough to use routinely.

Titan is deliberately a **separate language**, not a gradual type checker
layered onto existing Lua scripts. Restricting dynamic features that defeat
ahead-of-time optimization—such as arbitrary metatables on Titan structs or
polymorphic numeric dispatch—is what lets the compiler emit straight-line C
without fallback paths.

## Five core design commitments

1. **Lua compatibility outranks expressiveness.**
   Titan values cross into Lua and back cleanly; a feature that has no
   faithful Lua representation or changes the meaning of Lua-looking code does
   not belong in the language. Arithmetic reproduces Lua bit for bit—including
   floor division (`//`), modulo (`%`), shifts, overflow, and exact mixed
   `integer`/`float` comparisons—even where C's operators disagree. Truthiness
   follows Lua everywhere: only `nil` and `false` are falsy.

2. **Safety at the boundary is non-negotiable.**
   Where Lua absorbs an unexpected type by coercing, consulting a metamethod,
   or taking a slow generic path, Titan fails early with a clear runtime
   error. Crossing from Lua or an explicit `as` cast applies a consistent
   target-directed conversion; typed reads from Arrays, Maps, and implicit
   `value` projections enforce strict runtime guards. Lua code can never
   corrupt Titan's type invariants—the worst it can trigger is a normal error
   thrown back across the boundary. The sole unsafe escape hatch is the C
   foreign function interface (`foreign`), which is syntactically explicit.

3. **Optimization-friendly data on a single garbage collector.**
   Lua uses one table structure for everything; Titan splits its data so the
   compiler can specialize storage directly:
   - **Arrays (`{T}`)** are dense, positive-indexed containers with
     deterministic `#` length, exposed to Lua through canonical userdata
     proxies so Titan reads and writes skip generic hash dispatch.
   - **Maps (`{K: V}`)** are ordinary Lua tables for key/value lookup and
     seamless table interoperation.
   - **Records** are fixed-slot nominal structs whose field accesses compile
     to indexed loads rather than table lookups.
   - **Tagged unions** are closed nominal sums with positional or named
     payload parts and direct tag dispatch in `case`.
   - **Interfaces** provide nominal behavioral views satisfied structurally at
     conversion sites, wrapping concrete records or unions without making
     concrete layouts structural or requiring runtime method search.

   All Titan values live on Lua's garbage collector—no reference counting, no
   second heap, and no cross-runtime cycles.

4. **Pay-as-you-go dynamism without general subtyping.**
   Static types are the default, but interoperating with Lua requires explicit
   escape hatches. Option types (`T?`) give nil-tolerant code a checked,
   first-class shape with automatic checked unwrapping at use sites; `value`
   holds any Lua-representable value while keeping operations around it
   statically checked until narrowed. Titan avoids general subtyping: direct
   conversions (`integer` to `float`, `T` to `T?`, concrete record to
   Interface) apply at typed sinks and never silently lift through containers
   or function types, keeping performance costs visible and local.

5. **Lean on existing toolchains.**
   Titan compiles to C and hands optimization to the system C compiler—and to
   `wasi-sdk` Clang and Binaryen `wasm-opt` when targeting WebAssembly in the
   browser—rather than maintaining a custom code generator or JIT. Generated C
   targets Lua's
   typed Lua C API, avoiding redundant stack shuffling and type checks. The
   trade-off is explicit: each Titan release pairs with a pinned minor version
   of Lua (Lua 5.5.1), trading version independence for predictable,
   straight-line native code.

## Lineage

Titan grew out of LabLua at PUC-Rio. Its lineage begins with **Typed Lua**,
which explored adding static types to Lua itself, and led to the insight that
a restricted, ahead-of-time-compiled sister language could achieve far better
predictability and speed. Hugo Musso Gualandi presented that design at the
Lua Workshop 2017 alongside André Maidl, Fabio Mascarenhas, Gabriel Ligneul,
and Hisham Muhammad,¹ and the group built the initial `titan-v0` compiler.

The work subsequently branched along two complementary goals:

- **Pallene**, led by Hugo Gualandi, pursued a minimal Lua-subset language
  focused on compiler research and gradual-typing performance studies.
- **Titan**, led by Fabio Mascarenhas, pursued a complete, practical systems
  language—adding separate compilation and multi-module providers, nominal
  records, unions, Interfaces, generics, first-class closures, `defer`/`catch`
  error handling, a direct C FFI and C callback subset, a rich libuv-backed
  asynchronous and multi-threaded standard library, and a WebAssembly browser
  target.

For how these principles translate into the compiler, runtime, and generated
C, see the [implementation documentation](../implementation/index.md).

---

¹ Hugo Musso Gualandi, *Titan: A System Programming Language made for Lua*,
Lua Workshop 2017 ([slides](https://www.lua.org/wshop17/Gualandi.pdf)).
