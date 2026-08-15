# Design philosophy and history

Titan is a statically-typed, ahead-of-time-compiled programming language
designed as a *sister language* to [Lua](https://www.lua.org): it looks
and feels like Lua, runs inside the Lua runtime, operates directly on Lua
data, and exists for one reason — to let the performance-sensitive parts
of a Lua system be written in something that is still recognizably Lua.
This chapter explains the reasoning behind that design, where the project
came from, and the principles that decide what goes into the language.

## The problem Titan answers

Lua programmers who care about performance learn a private dialect of
contortions: caching library functions in locals, writing
`xs[#xs + 1] = v` instead of `table.insert`, replacing `ipairs` with a
manual numeric loop. The language is high-level, but its users routinely
trade that away, line by line, for speed. The founding observation of
Titan (presented by Hugo Musso Gualandi at the Lua Workshop 2017, in
collaboration with André Maidl, Fabio Mascarenhas, Gabriel Ligneul and
Hisham Muhammad¹) was that there are only two ways out of this:

1. **Optimize the Lua implementation.** The state of the art is
   just-in-time compilation, and Lua is lucky to have LuaJIT, a
   best-in-class JIT. But JITs are labor-intensive to build and maintain,
   their tooling is an open problem, they lag behind language evolution,
   and they do not optimize evenly — the gap between code the JIT
   compiles well and code it punts on can be an order of magnitude, and
   it is hard to predict which side of the gap a program falls on.

2. **Use a different language for the hot parts.** This is the original
   scripting-language bargain: the scripting language is dynamically
   typed, interpreted, flexible glue; the system language is statically
   typed, compiled, structured and efficient; each plays to its
   strengths. For Lua that traditionally means C through the C API — but
   the C API is hard to use, stack-based, and semantically mismatched
   with Lua. Rewriting in C is only worth it for large chunks of code,
   both because of the rewriting effort and because every crossing of
   the language boundary costs.

Titan is a bet on the second path, redesigned so that the bargain stops
hurting: a system-programming language *made for Lua*. Instead of pairing
Lua with C, pair it with a language that has Lua's syntax and data model
but a static type system and an ahead-of-time compiler. The programmer
moves a function or a module — not a whole program — across the boundary,
and the boundary itself is engineered to be nearly free.

It is worth stating what Titan is *not*. It is not Typed Lua: the goal is
not to add annotations to existing Lua programs and check them, but to
define a new language that is free to restrict Lua's semantics where
those semantics are what make Lua slow. Titan's semantics are close to a
*subset* of Lua — close enough that a Lua programmer can read and write
Titan immediately — but it is a different language, and it makes
different promises.

## The core commitments

**Seamless interoperation.** A compiled Titan module is, from Lua's point
of view, just a module: you `require` it, call its functions, read and
write its exported variables, index its records. Titan functions receive
and return Lua-compatible values; Maps are ordinary Lua tables, while Arrays
cross the boundary as canonical Titan userdata proxies over private Lua
tables. Titan shares Lua's garbage collector rather than bringing its own.
Crossing from Lua into Titan costs one target-directed dynamic conversion per argument —
comparable to what a careful C function would do with the `luaL_check*`
API. Exact Titan-to-Titan calls cost nothing beyond a C function call. A
statically known non-exact callable edge may realize a fresh target-tagged
native adapter; when it cannot, a branded value keeps the strict generic entry
instead of pretending to be a Lua boundary. Genuine Lua still calls the source
coercive entry. Container crossings remain shallow:
genuine-Lua Array writes are dynamically converted by the Array's carried
writer, raw Lua Map writes are not intercepted, and every later typed
Array/Map read strictly establishes the requested value before native use.
The distinction is where Titan's safety lives: dynamic conversion is applied
only at an explicitly dynamic boundary, while gradual views pay strict checks
when their contents are observed. The canonical split is the
[normative boundary matrix](types.md#normative-boundary-matrix). (See
[Lua interoperability](lua-interop.md) and, for the machinery,
[the implementation documentation](../implementation/lua-interop-internals.md).)

Interfaces keep that boundary explicit. A statically known satisfying record
or union converts by constructing a nominal wrapper; Lua and `value` can pass
an existing exact wrapper but never discover an implementation from a bare
value. This preserves a faithful userdata representation and a well-defined
error instead of adding hidden structural search at a dynamic edge.

**Fail early instead of falling back.** Where Lua reacts to an unexpected
value by taking a slower generic path — coercing, consulting a
metamethod, growing a representation — Titan raises an error. If a
parameter is declared `{integer}` and receives something else, that is a
run-time error at the boundary; if `xs[i]` does not hold an integer where
an integer is promised, that is a run-time error at the access. These
restrictions are not incidental: they are what allow the compiler to
generate straight-line C with unboxed values and no fallback paths, and
they double as compiler-checked documentation of what the code actually
expects. The flip side of the bargain is honored dynamically — the checks
never silently disappear, so Lua code can never corrupt Titan data, only
get an error thrown back at it.

**Optimization-friendly data.** Lua has exactly one table data structure;
Titan deliberately splits its container types. Arrays (`{T}`) are canonical
userdata proxies over private, array-part-only backing tables; maps (`{K:V}`)
remain ordinary Lua tables. Both can be handed to Lua, but only Titan creates
valid Array proxies. The static types let the compiler use their storage
directly, skipping generic VM access paths. Records are also userdata:
nominal, fixed-shape values with their fields at fixed slots, the moral
equivalent of structs, designed so that `p.x` compiles to an indexed load
rather than a hash lookup. Nominal [unions](unions.md) apply the same idea to
alternatives: one absolute integer tag and at most one fixed payload slot
permit direct construction and switch dispatch while `case` keeps the
representation opaque. The FFI extends the same idea outward: C
functions and C pointers get Titan types, so binding a C library is a
declaration, not a hand-written adapter. (History note: in the 2017
slides records were spelled `struct` and the FFI was an inline
`foreign C [[...]]` block, LuaJIT-style; they became `record` and
`foreign import "header.h"` as the design matured.)

Nominal [Interfaces](interfaces.md) add behavioral abstraction without turning
record or union layout structural. Direct concrete calls stay specialized;
conversion constructs a compact wrapper whose declaration-order vtable
supports calls through the Interface contract. Wrapper allocation and identity
are visible consequences of requesting that abstraction.

**Pay-as-you-go dynamism.** Static types are the default, but Lua is next
door, and pretending otherwise would make the boundary unusable. The
`value` type is the deliberate escape hatch: a `value` can hold anything
Lua can produce. Conversions from ordinary non-C Titan values *to* `value`
are free and implicit; a boxable C scalar first checks its
`lua_Integer`/`lua_Number` carrier, while C aggregates and function pointers
are not boxable. Conversions *from* `value` are implicit where the context names a type —
compiled, like the boundary, into a single run-time check. Option types
(`T?`) play the same role for the smaller question of "this or nil",
giving nil-tolerant code a checked, first-class shape instead of an
untyped one. The design intent in both cases is the same: dynamism is
available, explicit in the types, and paid for only where it is used.

Titan consequently does not need general subtyping. Even `T -> T?` is a named
conversion because representations may differ, and concrete-to-Interface use
is another direct conversion with a wrapper. Neither automatically lifts
through an Array, Map, or Function; gradual consistency remains the separate,
symmetric relation used for checked views.

**An implementation that leans on what exists.** Titan compiles to C and
hands the result to the system C compiler — no interpreter of its own, no
JIT, no custom backend; decades of C toolchain do the optimizing. More
unusually, the generated C bypasses the Lua C API and works directly
against the interpreter's internal headers. The C API is "dynamically
typed" — every operation re-checks its operands, adjusts stacks, guards
errors — and Titan's static types make almost all of that redundant. Going
under the API is measurably faster and allows real specialization (an
array access compiles to an array access), at a known cost: each Titan
release is tied to a specific minor version of Lua, and tracking a new
Lua release means re-deriving the generated code against the new
internals. The project has paid that cost knowingly — most recently in
the [migration from Lua 5.3 to Lua 5.5](../lua-5.5-migration.md), which
documents exactly how much of the generated code the internals touch.

## A short history

Titan grew out of LabLua at PUC-Rio. The lineage starts with Typed Lua
and the question of what static types could do for Lua; Titan's answer —
a separate, restricted, compiled sister language rather than annotations
over Lua — was taken to a proof of concept by the five workshop authors
in late 2017, as the `titan-v0` compiler whose git history this
repository still continues.

The project then forked along its two natures. Hugo Gualandi's
continuation became **Pallene**, the research vehicle: a minimal
Lua-subset language for studying the performance of gradually-typed
sister languages, kept small on purpose. **Titan** continued as the engineering track under Fabio
Mascarenhas, accumulating the features a practical language needs. The
pull-request history tells that story directly: the typechecker
sketch (#20) and the early code generator (#26, #29, #35); module-level
globals (#33) and the GC-safety discipline (#56); a real module system
with separate compilation and dynamic loading (#40/#44, #66, #81); the
`value` type and explicit casts (#92); the C FFI by Hisham Muhammad
(#107), who also contributed maps (#229) and the Lua-faithful semantics
for `//`, `%` and shifts (#216); multiple returns and multiple assignment
(#172, #178); records with methods (#201); standalone executables (#230);
making compiled modules loadable by a stock Lua, with no global C state so
one module can serve several Lua states (#231, #233/#235); the
static-when-source, dynamic-otherwise linking policy (#237); option types
(#239, refined by #250, #255); and the beginnings of the error-handling
story (#257). The [implementation documentation](../implementation/index.md)
describes where each of these lives today.

The 0.19 prototype adds nominal tagged unions and non-exhaustive `case`.
Variants are deliberately not first-class types, constructors are positional,
and every arm is an ordinary full block. The first version therefore reuses
the existing nominal, function, option, and error-handling models instead of
creating parallel ones.

Starting with 0.20, the prototype separates gradual consistency from direct
and written coercions. Typed Array/Map observations and branded exact-tag
mismatches use strict guards, while written `value as/is T` and genuine Lua
boundaries share a broader target-directed conversion. Arrays carry their Lua-write
policy, and function closures distinguish exact native, strict Titan-generic,
and coercive Lua entries. ABI 0.22 later reuses that fixed closure/native
contract for conditional non-exact target wrappers: eligible source closures
get a consumer-local native adapter and strict relay, while other values retain
the generic fallback. This adds no provider ABI surface. It also adds nominal Interface declarations,
structural record/union satisfaction at statically known conversion sites,
fresh wrappers, concrete downcasts, and exact-wrapper-only dynamic boundaries.
These coordinated representation changes accounted for that ABI advance; ABI
0.21 retained the language model while advancing the matched Lua runtime to
5.5.1, and ABIs 0.22 through 0.25 retain that model.

## Principles, distilled

When a design question comes up, the project has historically resolved it
by these lights, roughly in order:

1. **Lua compatibility outranks expressiveness.** Titan values cross into
   Lua and back; any feature that would give Titan values no faithful Lua
   representation, or that would change the meaning of Lua-looking code,
   is suspect. Arithmetic, for instance, follows Lua exactly — `//`, `%`
   and shifts reproduce Lua's results bit for bit even where C's
   operators disagree.
2. **Safety at the boundary is non-negotiable.** Lua code must not be
   able to corrupt Titan data structures or type assumptions; the worst
   it can get is a run-time error with a good message. Checks may be
   moved and deduplicated, never dropped.
3. **The Lua GC is the only GC.** Titan allocates Lua objects, keeps them
   visible to Lua's collector at every step, and emits the write barriers
   the collector requires. No reference counting, no shadow heaps.
4. **Performance comes from specialization, not cleverness.** The
   compiler wins by knowing types and shapes statically and emitting the
   obvious direct code, then letting the C compiler optimize. Where Lua
   semantics demand branches (shift amounts, division signs), they are
   written so constant operands let the C compiler delete them.
5. **Restrictions are features when they buy the above.** Nominal
   records, unions, and Interfaces, no user-defined metatables on Titan data — each is a smaller
   language in exchange for a faster and more predictable one, and each can
   be revisited as the design matures (see the roadmap in the
   [README](../../README.md)). First-class functions began as one of these
   restrictions and have since been lifted: functions are now values that
   can be stored, passed, returned and called — with a zero-overhead fast
   path for exact Titan-to-Titan calls — and that has grown to include
   anonymous functions that close over enclosing locals and bound instance-
   method references; only foreign/FFI functions remain non-values.

---

¹ Hugo Musso Gualandi, *Titan: A System Programming Language made for
Lua*, Lua Workshop 2017 —
[slides](https://www.lua.org/wshop17/Gualandi.pdf). The framing of the
problem and the core commitments in this chapter follow that
presentation; the post-2017 history is reconstructed from the project's
pull-request record.
