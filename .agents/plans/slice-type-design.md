# Slice type for Titan — design research & recommendation

Status: research / planning (not yet implemented). Roadmap item: *"slice type (native
array with length and capacity), variadic functions using a slice to collect variadic
arguments (Go-like)"*. This doc evaluates that "Go-like" framing against alternatives and
recommends a concrete representation that fits the Lua 5.5 allocator/GC and the existing
Titan codegen.

**UPDATE**: taken out of the roadmap and put on hold for more evaluation

Two evidence streams feed this:

- **Web research** (deep-research workflow, 21 sources, 25 adversarially-verified claims).
  Cited as `[tag]` with URLs in the *Sources* section.
- **Local source reading** — the in-tree `lua-5.5.0/src` and `titan-compiler/`. Cited as
  `file:line`. These are authoritative for the exact versions we target.

---

## 0. TL;DR recommendation

1. **Don't reuse a plain Lua table** (that is the current `{T}` array, and it is exactly
   what Pallene does — see §2). A slice is a **dedicated GC object** so it can keep an
   explicit length and, for scalars, an **unboxed** contiguous C array.

2. **Representation: a thin "slice header" full userdata + a separate backing GC object.**
   - Header = `luaS_newudata(L, sizeof(SliceRep), 1)`: **one user value** `uv[0]` holding
     the backing object (GC-traced, written with the **back barrier**), and a raw payload
     `struct { lua_Integer offset, len, cap; }` in the userdata's memory area (never GC-scanned).
   - Backing for **scalar** element types (`integer`/`float`/`boolean`) = a second
     *zero-user-value* userdata whose raw payload is the unboxed C array `T[cap]`. The GC
     never scans it; no barriers; `&backing.raw[offset]` is a valid `lua_Integer*` /
     `lua_Number*` to hand to C. **This is goal #2.**
   - Backing for **collectable / `value`** element types (`string`, records, arrays, maps,
     `value`) = a **Lua `Table`** (a GC object that traces its own elements and grows
     itself). Reuses all existing Titan array codegen; elements are boxed `TValue`s, which
     is unavoidable for pointer-typed elements on the Lua heap anyway.
   - The metatable pointer **is** the type tag (consistent with how records already work,
     coder.lua / current ABI) and carries the Lua-facing `__index`/`__newindex`/`__len`.

3. **Unboxed vs. boxed under one surface type** = specialize the representation per element
   type — the **.NET reified-generics** pattern `[dotnet-list]`, *not* Java/Pallene erasure
   to a uniform boxed array.

4. **Gradual typing: check on writes, never on reads, and make `[T]` invariant.**
   Reads from a statically-typed scalar slice are bare loads (no tag check) because the
   backing is type-homogeneous *by construction*. Writes of a `value` into a typed slot go
   through Titan's **existing** `value→T` cast (`checkandget`, coder.lua:193) — that *is*
   "check on write," and it is already how Titan handles every scalar cast. Making `[T]`
   invariant (no `[integer] <: [value]`) closes the aliasing hole that would otherwise let
   an untyped write bypass the cast. Grounded in monotonic references `[monotonic]` and
   transient gradual typing `[transient]`.

5. **v1 scope:** ship fixed-capacity-but-dynamically-sized slices + sub-slices + variadic
   collection. Growth (`append` with doubling) is a small, well-isolated addition and is
   worth shipping too; the only subtlety it adds is Go-style **untethering**, which we
   document rather than engineer around.

6. **Variadic args:** the **caller** collects the extra arguments into a slice and passes
   it as one ordinary slice parameter; the callee sees `...` as a normal `[T]`. The slice's
   explicit `len` is what makes a `nil` argument in the middle not truncate the count
   (goal #1).

---

## 1. What problem the slice actually solves (vs. today's `{T}` arrays)

Today a Titan array `{T}` is a plain `Table*` (coder.lua `ctype(Type.Array)` → `"Table*"`),
indexed with the Lua 5.5 fast paths (`luaH_fastgeti`/`obj2arr`) and length via
`luaH_getn`. That inherits three Lua properties the slice must *not* inherit:

- **`#` is a border, not a count.** With a hole (`nil` in the middle) `luaH_getn` may return
  any border. Useless for backing a variadic list where "how many args were passed,
  including nils" must be exact (**goal #1**).
- **Elements are boxed `TValue`s** (tag + value). A `{float}` cannot be handed to a C
  `double*` (**goal #2**).
- **No stable capacity / no contiguity guarantee** you can lean on for C interop or
  sub-slicing.

The slice is the *dense, length-exact, unboxed-capable, C-interoperable, sub-sliceable*
counterpart. The two types coexist; `{T}` stays the Lua-idiomatic table.

---

## 2. Prior art (and why "Go-like" is right on layout but Pallene is the cautionary tale)

### Pallene — the negative precedent (most important finding)

Pallene (Gualandi & Ierusalimschy), Titan's direct academic predecessor, **deliberately
represents every typed array as a plain Lua table of boxed values.** In its IR the *only*
array type is `{any}`; `{integer}`/`{float}` are all lowered to `{any}`, scalars are boxed
on write and unboxed *with a tag check* on read, and `coder.lua` maps the array type to C
`Table *` `[pallene-thesis][pallene-sblp][pallene-manual]`. The thesis is explicit: *"all
arrays are implemented as `{any}` because we want to implement Pallene arrays as Lua tables
and because we want to allow Pallene to use arrays created by Lua."* Reads pay a tag check
*"because Lua might have written values of the wrong type to the field"* `[pallene-sblp]`.

Consequence for us: **Pallene does not meet goal #2 at all** — there is no unboxed
contiguous storage and nothing to pass to C. If Titan's slice were "a Lua table with a
length field" it would be Pallene-with-a-counter and would forfeit the main reason to add
the type. **This is the single strongest argument for a dedicated representation.**

Notice the symmetry the research drew out `[pallene-sblp][pallene-thesis]`: Pallene must
check on **reads** because the shared Lua table can be mutated to the wrong type behind its
back. An **unboxed** slice that Lua physically cannot type-violate inverts this — precision
is established at the **write** boundary and the backing store *cannot* hold a wrong-typed
value, so reads need no check. That is the dual of Pallene and the formal justification for
the user's "check on writes" instinct (developed in §5).

### Go slices — sound blueprint for the *header* and for sub-slicing

A Go slice is a **3-word value header `{ptr, len, cap}`** over a separately-stored backing
array `[go-slices-intro][go-runtime-slice]`. Reslicing copies no data — a sub-slice is a new
header into the *same* backing array, so mutations through one are visible through another
`[go-slices-intro]`. Growth past `cap` allocates a new larger backing, copies, and returns an
**updated** header — which **untethers** the grown slice from the shared backing (the classic
gotcha) `[go-slices][go-gotchas]`. Capacity grows by ~doubling `[go-slices-intro]`.

This maps cleanly onto Lua: the header lives in a userdata, the backing is a separate GC
object, and because **Lua's GC never moves objects** the interior backing pointer is stable
and safe to hold and to pass to C (§4). We adopt Go's header shape and reslicing semantics;
we are *not* obliged to copy Go's exact growth ratio.

### .NET — the precedent for *unboxed* typed collections

.NET **reified generics** specialize `List<T>` per value type, so a `List<int>` stores
unboxed `int`s — no boxing `[dotnet-list]`. This is the opposite of Java (erasure forces
`ArrayList<Integer>` to box; only the primitive `int[]` is unboxed) and of Pallene. It
validates **specialize-the-slice-per-scalar-type** as the way to get unboxed storage under
a managed runtime. `Span<T>` is .NET's "interior pointer into a backing buffer" abstraction;
the research did not independently source its byref internals, but conceptually it is the
sub-slice/interior-view idea we use.

### Others (lighter coverage)

Julia's `Array` is a header + separately-allocated data with shared-data slicing; LuaJIT FFI
`cdata` arrays + `table.new`/`table.clear` are the established "unboxed array on a Lua-family
runtime" trick. The workflow did not land independently-verified claims on Julia's
`jl_array_t`, LuaJIT cdata, Luau, or Terra, so I treat those as corroborating-but-unsourced
(see *Caveats*). They don't change the recommendation.

---

## 3. The governing Lua 5.5 facts (verified against in-tree source)

These are the constraints any representation must satisfy. All confirmed by reading
`lua-5.5.0/src`.

**F1 — A userdata has two storage areas with opposite GC treatment.**
`Udata` (lobject.h:491-498) = `CommonHeader; unsigned short nuvalue; size_t len;
Table *metatable; GCObject *gclist; UValue uv[1];`, with the **raw memory area following the
struct** (`getudatamem`, `udatamemoffset`, lobject.h:520-528). The raw area is
**max-aligned** (`UValue`/`Udata0.bindata` embed `LUAI_MAXALIGN`, lobject.h:480-516) — fine
for `double`/`lua_Integer`. GC traversal:

```c
/* lgc.c:631-638 */
static l_mem traverseudata (global_State *g, Udata *u) {
  markobjectN(g, u->metatable);              /* metatable is traced   */
  for (i = 0; i < u->nuvalue; i++)
    markvalue(g, &u->uv[i].uv);              /* each uv[] slot traced  */
  genlink(g, obj2gco(u));                    /* genlink → back-barrier-safe */
}
```

So: **`uv[]` slots are traced GC references** (collectable elements stored there stay alive
and need a barrier on store); **the raw payload is opaque** (perfect for unboxed scalars —
no marking, no barriers) `[lua-gc-traverseudata]`.

**F2 — Userdata is fixed-size once allocated.** `luaS_newudata(L, s, nuvalue)`
(lstring.c:286) fixes *both* the raw byte count `s` and `nuvalue` at creation; Lua never
grows a userdata in place. ⇒ **a growable slice cannot store its data inline in the header
userdata**; growth means allocating a new backing object and repointing.

**F3 — Back barrier is the right barrier, and it is `genlink`-safe on userdata.**
`luaC_barrierback(L, p, v)` (lgc.h:251) fires `luaC_barrierback_` only when
`isblack(p) && iswhite(v)`; it relinks `p` onto `grayagain` (lgc.c:268-279). Because
`traverseudata` calls `genlink` (F1) — unlike `traverseCclosure`, which does **not**
(lgc.c:661-666) — storing a collectable into a userdata `uv[]` slot with the *back* barrier
does not float fresh values to the old generation. This is the same rule records already
follow (records store fields with `luaC_barrierback`, coder.lua). `lua_setiuservalue` is the
in-tree precedent: it `setobj`s into `uv[n-1]` then `luaC_barrierback`s (lapi.c:1004-1021).
**Overwrite vs. append use the same barrier.**

**F4 — Separate `luaM_*` buffers are GC-accounted, and the collector is non-moving.**
`luaM_realloc_` adjusts `g->GCdebt` by the size delta (lmem.c:187), so a separately
allocated backing block is *visible* to GC pacing, not "invisible" memory. `luaM_growaux_`
already implements 2× doubling with `MINSIZEARRAY = 4` (lmem.c:94-119). Lua 5.5 has only
incremental / generational-minor / generational-major modes (lstate.h) — **no compaction**;
objects never move, so interior pointers and C-handed buffers stay valid for the object's
lifetime `[lua-gc-modes]`.

**F5 — Generational mode reuses the incremental barriers.** Barrier-correct code is correct
in both GC modes (the embedder can switch modes at runtime) `[lua-gc-modes]`. So we only have
to get the barriers right once.

**F6 — Lua's own table array part is the in-tree model for a "slice of boxed value."**
Lua 5.5 stores a table's array part as **one allocation holding a `Value[]` plus a separate
tag-byte array** (`concretesize = size*(sizeof(Value)+1)+sizeof(unsigned)`, ltable.c;
`obj2arr`/`arr2obj`/`luaH_fastgeti`). For the boxed-element case we get all of this for free
by *using a real `Table` as the backing* rather than re-implementing it.

### Consequence: avoid `__gc` finalizers in v1

A raw `luaM_*` block + a `__gc` finalizer to free it (the "userdata owns a C buffer" idiom)
is *possible* (F4) but brings finalizer ordering caveats (the metatable's `__gc` must be set
before `luaC_checkfinalizer`, lgc.c/lapi.c) and a **sub-slice use-after-free hazard** (which
header's `__gc` frees the shared block?). **Making the backing a first-class GC object
(a userdata or a `Table`) sidesteps all of it**: the GC frees it automatically when the last
header referencing it (via `uv[0]`) dies, no finalizer needed, and sub-slices keeping the
backing alive is just ordinary reachability. This is the decisive reason the backing is a
GC object, not a raw block.

---

## 4. Recommended representation

### 4.1 The slice header (uniform across element types)

```
slice header  =  full userdata, luaS_newudata(L, sizeof(SliceRep), /*nuvalue=*/1)

  uv[0]  : GCObject*  backing            -- TRACED; stored with luaC_barrierback
  raw    : struct SliceRep {
             lua_Integer offset;         -- start index into backing (for sub-slices)
             lua_Integer len;            -- logical length (THE stable count, goal #1)
             lua_Integer cap;            -- capacity from 'offset' to end of backing
           }
  metatable : per-element-type metatable -- type tag (== record convention) + __index/__newindex/__len
```

- The header is tiny and uniform; only `uv[0]`'s *referent* differs by element kind.
- `offset`/`len`/`cap` live in the **raw, untraced** payload (they are integers — F1).
- Storing/replacing `uv[0]` uses `luaC_barrierback(L, header, backing)` (F3).

### 4.2 Backing, by element kind (reified-generics style, §2 .NET)

**Scalar `[integer] / [float] / [boolean]`** → backing is a **zero-user-value userdata**
(`luaS_newudata(L, cap*sizeof(T), 0)`); its raw payload *is* the unboxed `T[cap]`. GC never
scans it (F1). `&backing.raw[offset]` is a `lua_Integer*`/`lua_Number*` ⇒ **goal #2**. No
barriers on element writes. Growth = allocate a bigger backing userdata, `memcpy`, repoint
`header.uv[0]` (with back barrier).

**Collectable / `value` `[string] / [Point] / [value] / [{integer}]`** → backing is a
**Lua `Table`**. Element reads/writes reuse the existing array codegen
(`luaH_fastgeti`/`obj2arr` + `luaC_barrierback`), bounds-checked against the slice's own
`len` (not the table border — goal #1). The table traces its own elements and grows itself
(F6). Boxing here is not a regression: a heap array of strings/records is boxed in *every*
managed runtime; goal #2 (a C scalar vector) is meaningless for pointer elements.

Both share the *same header layout and metatable machinery*; they differ only in the kind of
object in `uv[0]` and in whether element access is a bare C array index or a `luaH_*` call.
The element kind is known statically at the access site (so codegen picks the right path
with no runtime branch) and is *also* recoverable at runtime from the metatable (for the
`value`-typed polymorphic path and for Lua-facing access — §5, §7).

COMMENT: the 65K limit on the number of userdata values is unfortunate, because a Table
as backing storage adds yet another layer of indirection, since you have <header udata>
-> <backing table> -> <array part>.

### 4.3 Why not a single inline userdata?

A single userdata (`luaS_newudata(L, sizeof(len)+cap*sizeof(T), 0)` holding `len` + inline
`T[cap]`) is the *cheapest* fixed-size scalar slice — one allocation, no `uv[]`. It is a
valid **specialization** for non-growable, non-shared scalar slices and we may emit it as an
optimization. But it cannot grow (F2) and a sub-slice into it would need to hold the parent
alive via its own `uv[0]` anyway — so the general path is the header+backing split of §4.1.
Recommendation: implement the general split first; add the inline specialization later if
profiling wants it.

COMMENT: even with growable slices this is a pretty straightforward optimization,
and avoids an indirection for every element access to the original slice. Information in the
header could mark whether the slice has the backing storage inline or not, and slices where
`capacity > 0` (and < 65K for collectable)>) would be created this way. The first user value
would be reserved. On first growth a new backing object is allocated, the first user value
points to it, and the header is updated. Taking a subslice allocates a new header udata pointing
its `uv[0]` to the original.

---

## 5. Gradual typing: where the check lives

The crux (goal #4): a `[integer]` is unboxed; a context typed `[value]` expects "a collection
of any." Resolution, grounded in the research:

**Reads are always unchecked on the static side.** Monotonic references `[monotonic]`: if a
reference has a fully static type, the heap cell *must* already hold a value of that type, so
the access compiles to a plain load/store — *"the cost of a load or store instruction for
primitive data types"* — and whether a coercion is needed *"can be distinguished during
compilation, based on whether the reference expression has a fully static type."* A scalar
slice's backing is type-homogeneous by construction, so `s[i]` for `s: [integer]` is a bare
`lua_Integer` load. No Pallene-style read check.

**Writes from `value` carry the check — and Titan already does exactly this.** Storing a
`value` into a typed slot is the `value→T` coercion the checker already materializes as an
`Ast.ExpCast` and the coder already lowers to `checkandget` (coder.lua:193-312): for
`integer` it does `ttisinteger` → use, else float-with-integral-value → convert, else throw.
**That is "check on write."** Transient gradual typing `[transient]` is the matching
discipline: constant-time checks that inspect only the top-level tag, no proxies — precisely
a tag-check-then-unbox at the write site.

**Make `[T]` invariant to close the aliasing hole.** The only way an *unchecked* wrong-typed
value reaches an unboxed backing is by aliasing a `[integer]` as `[value]` and writing
through the alias. Forbid `[integer] <: [value]` (mutable collections are invariant in every
sound system — Java's covariant `Object[]` is the textbook unsoundness; Go has no such
subtyping; .NET `List<T>` is invariant). Then every write to a typed slice goes through the
materialized cast, and there is no untyped back door.

COMMENT: That was why I mentioned having this alias be a new value (similar to a sub-slice)
backed by the original slice, again the header could have the tag necessary to implement
the runtime checks on writes, and the boxing on reads, with no copying is needed, this is O(1). 
Going from `[integer] -> [value] -> [integer]` would check this tag and if successful yield
a regular sub-slice, and again O(1).

**If/when we do want to pass `[integer]` where `[value]` is expected** (the user's literal
scenario), the clean implementation is a **representation-polymorphic `value` access path**
that dispatches on the element kind recovered from the metatable: read → box the scalar;
write → `checkandget` the incoming `value` to the backing's scalar type, then store unboxed.
The static `[integer]` path never pays for this; only code that *statically* holds the slice
at type `[value]` takes the dispatched path — exactly the compile-time-decidable fast/slow
split of `[monotonic]`. **Recommendation:** ship invariant `[T]` with an explicit, O(n)
`[integer] → [value]` boxing conversion in v1; add the zero-copy representation-polymorphic
`value` path later only if a real use case demands it. (It is additive, not a v1 blocker.)

---

## 6. Sub-slices, growth, and untethering

**Sub-slice** = a new header userdata with the **same `uv[0]` backing**, a larger `offset`,
and a smaller `len`/`cap`. No data copied (Go semantics `[go-slices-intro]`). The backing
stays alive because *every* header references it through a traced `uv[0]` slot (F1) — no
refcounting, no `__gc`, no use-after-free. This is the payoff of "backing is a GC object"
(§3 *Consequence*).

**Growth** (`append`): if `len < cap`, write in place and bump `len`. If `len == cap`,
allocate a bigger backing (≥2× per `luaM_growaux_`, lmem.c:109), `memcpy` (scalar) or
re-point (table), and update `header.uv[0]`. Per F4 the new block is GC-accounted; per F2
this is the only way to grow at all.

**Untethering is inherent and we document it, not engineer it away** `[go-slices][go-gotchas]`:
after a growth that reallocates, the grown header points at the *new* backing while
sub-slices still point at the *old* one — subsequent mutations no longer alias. This is Go's
exact gotcha and the user already flagged it. Options, in order of preference:
(a) document it and match Go (recommended — least surprise for anyone who knows Go);
(b) make `append` *always* copy (no in-place growth) so sharing is never silently broken at
the cost of more allocation; (c) make sub-slices read-only views. I recommend (a) for v1.

COMMENT: Perhaps the cleanest is to make sub-slices non-growable to begin with? The user can always
allocate a fresh slice and copy the elements. And this makes it possible to go with
copy-on-grow for subslices later, while starting out with the Go behavior and moving to
always copying on growing is a big breaking change.

Growth also causes issues with C interop, but garbage collection also does, so I do not think
it is a dealbreaker, having C interop by passing a direct pointer to the backing array is
a trade-off of efficiency vs the user having to know very well what they are doing.

**Interior pointers are safe** because the GC is non-moving (F4) — a sub-slice's
`backing + offset` and any `lua_*`/C pointer into the scalar backing remain valid for the
backing's lifetime.

---

## 7. Variadic argument collection (the roadmap's actual driver)

The research found **no verified source** on how Go/Java/C# *lower* varargs into the callee
(angle (e) is an evidence gap — see *Caveats*), so this section is reasoned from Titan's own
calling convention (coder.lua `function_sig`: `RET f(lua_State *L, Udata *_mod,
CClosure *_fn, params..., out-params...)`) plus the well-known surface semantics of those
languages.

**Recommended ABI — caller-side collection, callee sees one slice:**

- For `function fmt(s: string, ...: integer)`, the variadic part lowers to **one ordinary
  `[integer]` parameter**. The native signature gains a single `SliceHeader* /* the [integer] */`
  argument — it composes with `_mod`/`_fn` by being just another typed parameter.
- At each **call site** the *caller* (which statically knows the count and types of the
  extra arguments) allocates a slice of exactly that length, fills it (raw-store for scalar,
  box for `value`/collectable), and passes it. The slice's explicit `len` = number of
  variadic args, **including any `nil`s** — that is the whole reason a slice, not a Lua table
  with `#`, backs varargs (goal #1).
- A spread call `f(existing_slice...)` (Go's `s...`) passes the slice directly with no
  re-collection.

This mirrors Go (`...T` → callee receives a `[]T`), Java (`T[]` varargs — caller builds the
array), and C# `params`. It keeps the callee uniform (a slice is a slice, however it was
produced) and keeps the variadic machinery out of the native convention's hot path.

**Open ABI question** (flagged honestly): whether the caller should stack-anchor the freshly
built slice header before the call (the existing convention already "anchors GC-able
arguments on the Lua stack") and the exact interaction with multi-return out-params. This is
mechanical but unspecified by any source; resolve during implementation.

COMMENT: The number of out-params remains fixed, there will be no such thing as a variadic **return**,
so I think it is fine. In Go are you able to mutate/grow these vararg slices? Because it you do that
and they are passed along without copying a mutation on the callee would be visible by the caller (same
as if this were just a regular slice parameter, since these are reference types).

Lua 5.5 has introduced an optional name to vararg parameters, so I would like to mandate those
in Titan so a bare `...` is not a valid expression (and the declaration would be like 
`function fmt(s: string, ...args: integer)`). Spread syntax would also be `...slice`. 

---

## 8. Fixed vs. growable, and the v1 cut

| Capability | Cost | Recommend in v1? |
|---|---|---|
| Stable explicit `len` (goal #1) | trivial (one int field) | **Yes** — the core reason for the type |
| Unboxed scalar backing (goal #2) | a 0-uv backing userdata + per-scalar codegen | **Yes** — the other core reason |
| `value`/collectable backing via `Table` | reuses array codegen | **Yes** |
| Sub-slices sharing backing (goal #5) | new header, same `uv[0]`; no new GC mechanism | **Yes** — cheap once backing is a GC object |
| Growth / `append` with doubling (goal #3) | reallocate-and-repoint; `luaM_growaux_` exists | **Yes** — small and high-value; accept untethering |
| Lua `__index`/`__newindex` (goal #6) | metatable methods over the header | **Yes** |
| Zero-copy `[T]`→`[value]` polymorphic path | runtime element-kind dispatch | **No** — defer; ship invariant `[T]` + explicit boxing conversion |
| Inline single-userdata scalar specialization | codegen variant | **No** — optimization, add later |

Growth is listed as a nice-to-have in the brief; my recommendation is to include it because
the chosen representation makes it nearly free (reallocate backing + repoint `uv[0]`), and a
non-growable slice that already needs dynamic allocation leaves most of the win on the table.
The only thing growth *adds* is untethering, which we document.

---

## 9. Concrete integration seams (from reading `titan-compiler/`)

- **types.lua:** add `Type.Slice = {"elem"}` (mirror `Type.Array`). Update by hand:
  `tostring`, `equals`, `compatible`/`coerceable` (slices **invariant** — §5),
  `serialize`, and `is_gc` (a slice value is always GC — it's a userdata).
- **checker.lua:** slice indexing (read yields `elem`, *not* `elem?` if we keep dense
  semantics — decide; write takes `elem`, with the existing `value→elem` cast materialized
  for gradual writes); slice constructor literal with `[ <elem type> ]` syntax; variadic
  parameter handling that types `...` as `[elem]`; skip `_ignore`d dup nodes as usual.
- **coder.lua:** `ctype(Type.Slice)` → `SliceHeader*` (a `Udata*`, like records). New
  templates for: header+backing allocation (scalar vs table backing), bounds-checked
  index read/write (bare C array load/store for scalar; `luaH_*`+`luaC_barrierback` for
  boxed), `#s` → read `header.raw.len`, sub-slice construction, `append`/growth, and the
  caller-side variadic collection. Reuse the `checkandget`/`setwrapped` cast plumbing for
  the gradual boundary. Advance the **module ABI** because slices are part of
  signatures.
- **runtime (titan.h / titan-runtime):** small helpers for slice alloc/grow/sub-slice and
  the metatable `__index`/`__newindex`/`__len` C functions, plus the per-element-type
  metatable registration (one per element type per module, like record metatables live in
  module `uv` slots today).

---

## 10. Caveats & open questions (honest gaps)

- **Variadic calling-convention ABI is unsourced** (§7). No verified source covered how
  Go/Java/C# lower varargs collection; the caller-collects design is reasoned from Titan's
  own convention and is the open implementation question.
- **No Julia / LuaJIT-cdata / Luau / Terra / `Span<T>`-internals** verified claims landed —
  they corroborate but didn't independently source the design. Doesn't change the
  recommendation.
- **Growable slices of *collectable* elements**: handled here by a `Table` backing (it
  traces + grows itself). The alternative — collectable elements in userdata `uv[]` slots —
  is capped (`nuvalue` is `unsigned short`, ≤ 65535) and fixed-size (F2), so it is **not**
  suitable as the general growable boxed backing. Table backing is the answer.
- **Untethering** (§6) is a real semantic wart inherited from Go; we choose to document
  rather than prevent it in v1.
- **No benchmarks.** Every efficiency claim here is mechanistic (allocation counts, barrier
  counts, tag-check elimination), not measured. The slice layout itself has not been built.
- The monotonic-references / transient-typing papers `[monotonic][transient]` are about
  reference cells and general values, not slices specifically; "slice element access =
  reference deref/update" is a sound design inference, not a directly-sourced claim.

---

## Sources

Web (deep-research, all claims 3-0 unless noted):

- `[pallene-thesis]` Gualandi, *PhD thesis* (2020) — http://www.lua.inf.puc-rio.br/publications/2020-HugoGualandi-phd-thesis.pdf
- `[pallene-sblp]` Gualandi & Ierusalimschy, Pallene SBLP paper — https://www.inf.puc-rio.br/~roberto/docs/pallene-sblp.pdf
- `[pallene-manual]` Pallene manual — https://github.com/pallene-lang/pallene/blob/master/doc/manual.md
- `[go-slices-intro]` Go blog, *Go Slices: usage and internals* — https://go.dev/blog/slices-intro
- `[go-slices]` Go blog, *Arrays, slices (and strings)* — https://go.dev/blog/slices
- `[go-runtime-slice]` Go runtime `slice.go` — https://github.com/golang/go/blob/master/src/runtime/slice.go
- `[go-gotchas]` Go slice gotchas — https://rednafi.com/go/slice-gotchas/
- `[dotnet-list]` .NET `List<T>` docs (reified generics, no boxing for value types) — https://learn.microsoft.com/en-us/dotnet/fundamentals/runtime-libraries/system-collections-generic-list%7Bt%7D
- `[monotonic]` Siek et al., *Monotonic References* (ESOP 2015) — https://link.springer.com/chapter/10.1007/978-3-662-46669-8_18 ; arXiv https://arxiv.org/abs/1312.0694
- `[transient]` Vitousek, Siek, Chaudhuri, *Transient gradual typing* (DLS 2019) — https://arxiv.org/pdf/1902.07808
- `[lua-gc-traverseudata]`, `[lua-gc-modes]` Lua 5.5 manual + lgc.c — https://www.lua.org/manual/5.5/manual.html , https://www.lua.org/source/5.5/lgc.c.html

Local source (authoritative for our targets):

- `lua-5.5.0/src/lobject.h:480-528` — `UValue`/`Udata`/`Udata0`, `getudatamem`, `sizeudata`
- `lua-5.5.0/src/lgc.c:631-638` — `traverseudata` (traces metatable + `uv[]`, calls `genlink`)
- `lua-5.5.0/src/lgc.c:661-666` — `traverseCclosure` (does **not** call `genlink`)
- `lua-5.5.0/src/lgc.h:241-252` — `luaC_barrier`/`luaC_barrierback` macros
- `lua-5.5.0/src/lstring.c:286` — `luaS_newudata(L, s, nuvalue)` (sizes fixed at creation)
- `lua-5.5.0/src/lmem.c:97-119,187` — `luaM_growaux_` (2×, MINSIZEARRAY 4), `GCdebt` accounting
- `lua-5.5.0/src/ltable.c` (`concretesize`, `obj2arr`/`arr2obj`) — table array-part layout
- `lua-5.5.0/src/lapi.c:1004-1021` — `lua_setiuservalue` (back barrier on `uv[]` store)
- `titan-compiler/coder.lua` — `ctype` map, `checkandget` (193-312), `function_sig`, array/record/map codegen, back-barrier field stores
- `titan-compiler/types.lua` — `Type.Array/Map/Record/Value`, `compatible`/`coerceable`
