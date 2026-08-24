# Dense arrays with holes — implementation plan

Status: implemented, locally validated, published in PR #38, and validated by
exact-head Linux CI. The representation decision in this revision supersedes
the earlier embedded-`Table`/patched-Lua draft.

Primary feature brief:
`/home/mascarenhas/.codex/attachments/18a18024-86e3-4d82-b799-f3432097e8fb/pasted-text-1.txt`

## 0. Accepted architecture

### 0.1 Representation

A Titan Array has two ordinary stock-Lua 5.5.0 GC objects:

```text
native/exact value
        |
        v
  backing Table  -- hash integer key 0 --> canonical proxy Udata
        ^                                      |
        |                                      |
        +------------- user value 1 -----------+
```

- The native and compiler-internal Array value remains `Table *`.
- The backing `Table` is allocated normally with `luaH_new`, is linked in
  Lua's ordinary GC lists, and owns its ordinary array/hash allocations.
- The Lua-visible value is a zero-payload full `Udata` with exactly one user
  value.
- Proxy user value 1 contains the backing `Table`.
- The backing table's reserved integer hash key `0` contains that one
  canonical proxy.
- The backing table has no metatable. The proxy has the shared Titan Array
  metatable.
- `t->asize` is capacity.
- When `t->asize > 0`, `*lenhint(t)` is Titan's authoritative explicit
  logical length. An Array with `asize == 0` has length zero and must not
  dereference `lenhint(t)`.

The two edges form a normal strong GC cycle. A live proxy keeps the backing
Table alive; a GC-scanned internal Table TValue/owner/root keeps the proxy
alive through key `0`; an unreachable pair is collected by stock incremental
or generational GC without any special traversal or freeing. A raw C
`Table *` local is not itself a root.

Integer key `0` is private metadata, not an Array element. This is safe
because the language contract is now:

- every read with index `< 1` returns nil without consulting the Table; and
- every write with index `< 1` raises before consulting or mutating the
  Table.

Negative user keys are never stored. Positive user entries are always in the
array part. Consequently the hash part contains exactly one live entry,
`0 -> proxy`, throughout the Array's lifetime.

### 0.2 Why this satisfies the performance constraints

Exact/native code indexes the same `Table *` as the current implementation.
The common GC-valued write remains:

```c
obj2arr(t, slot, &value);
luaC_barrierback(L, obj2gco(t), &value);
```

It does not first load a backing pointer from a userdata. Reads likewise start
from `Table *` and use the existing array-slot representation. A typed read
whose element type is itself Array may perform structural validation after
loading the slot; that is an element-type check, not an extra indirection to
reach the outer Array. Proxy recovery is paid at Lua-visible/`value`/raw-Map
boundaries and that nested-Array slow path, never on ordinary outer slot
addressing or the common typed write.

This trade-off is deliberately optimized for dense GC values. Dense numeric
code that needs a more specialized representation can continue to lower to an
FFI array. Allocation does pay for one additional zero-payload Udata and one
hash node per Array; that cold/storage cost is accepted in exchange for
preserving the indexed hot path.

### 0.3 Why stock GC is sufficient

Both headers are ordinary, independently allocated `GCObject`s. Stock Lua:

- marks the Table from the Udata user value;
- marks the Udata from the Table hash value;
- traverses Array elements as ordinary Table entries;
- accounts for and frees the Table's dynamic array and one-node hash blocks;
- frees the Udata through its ordinary allocation path; and
- collects the unreachable cycle normally.

There is no embedded `GCObject` header, manual `allgc` membership, custom
traversal, custom object-size accounting, special finalizer, registry owner
map, or Lua source patch.

### 0.4 Rejected alternatives

Do not reintroduce:

- an embedded-by-value `Table` inside Udata;
- a custom allocator that merely initializes an embedded Table header;
- manual linking of an interior Table header into a GC list;
- a `__gc` finalizer to free embedded Table storage;
- a Udata-native Array whose hot path loads a backing `Table *`; or
- a registry-side owner lookup on normal indexed operations.

Initializing an embedded header is not enough: stock Lua would still give
that header independent tracing/sweeping/freeing semantics that do not match
an interior allocation. The accepted design avoids the issue by making the
Table a real ordinary GC allocation.

No reserved bit in `Table.flags` is needed. Even if a stock-5.5 bit appears
unused, key `0`, the uservalue backlink, and the canonical proxy metatable are
the representation markers; do not add a gratuitous flag dependency.

## 1. Outcome and scope

This feature delivers:

- deterministic, constant-time Array length in the presence of holes;
- positive-only Array indices;
- power-of-two growth for indexed writes;
- the same direct `Table *` read/write hot path as existing Arrays;
- a canonical Lua-facing userdata proxy for each Array;
- ordinary stock Lua 5.5.0 GC ownership;
- safe ordinary-language Array/Map separation at Lua and `value` boundaries;
- contextual positional constructors for integer-keyed Maps;
- Lua table-border length for integer-keyed Maps;
- a compiled-module ABI boundary;
- updated standalone argument behavior;
- focused runtime/checker/coder/ABI/packaging coverage; and
- updates to both language and implementation manuals.

This feature does not:

- add Array or Map syntax;
- make Array and Map compatible or directly castable;
- parameterize the proxy metatable by element type;
- expose capacity or the backing Table as a supported API;
- add `pairs`, `rawget`, `rawset`, or `rawlen` support to the proxy; a Titan
  Array is table-like but not a Lua table, so stock `table.*` operations use
  its required metamethods without any separate Titan support;
- define deterministic length for a holed Map;
- change the physical exact-call representation from `Table *`;
- change `TitanVargArrayOrMap` from `Table **`; or
- patch Lua 5.5.0.

Debug-library or C-API access can reveal or mutate private user values and
Table internals. Such access explicitly opts out of Titan's safety contract;
using it to inspect or mutate an Array backing Table is undefined behavior.

## 2. Normative language semantics

### 2.1 Types and source syntax

The source type model remains:

- `{T}` is `Type.Array(T)`;
- `{K: V}` is `Type.Map(K, V)`; and
- Array and Map are distinct structural types. Compatibility recurses only
  between the same container kind.

Array and Map element/value types remain de-optionized as today. An indexed
read still has optional type (`a[i]: T?`, `m[k]: V?`) because an entry can be
absent. An indexed lvalue remains optionized, so assigning nil remains legal.

No parser or AST shape changes are required. `Ast.ExpInitList` fields already
distinguish positional fields, computed Map keys, named record fields, and a
trailing positional `Ast.ExpDots`.

### 2.2 Capacity, length, and storage invariants

For a positive Titan index `i`, the corresponding array-part slot is `i - 1`.

For a backing `Table *t`:

```c
capacity(t) = t->asize;
length(t)   = t->asize == 0 ? 0 : *lenhint(t);
```

Logical length is:

> the greatest positive integer index whose value is non-nil, or zero if no
> positive index is present.

The maintained invariants are:

- `0 <= length <= capacity`;
- every slot in `[length, capacity)` is empty/nil;
- when `length > 0`, slot `length - 1` is non-nil;
- slots below `length - 1` may be holes;
- no positive entry is stored in the hash part;
- no negative entry is stored anywhere;
- the hash part has one live entry at integer key `0`;
- that key's value is the canonical proxy whose user value points back to
  `t`; and
- `t->metatable == NULL`.

Thus length is not an element count or Lua's unspecified border-selection
result. It is necessarily one valid Lua border—the highest one—because
`a[length]` is present and `a[length + 1]` is absent:

```titan
local a: {value} = { 10, 20, 30 }
a[2] = nil
assert(#a == 3)
a[3] = nil
assert(#a == 1)
a[1] = nil
assert(#a == 0)
```

The state transitions are:

- A non-nil write at positive `i <= capacity` writes the slot and raises
  length to `i` when `i > length`.
- A non-nil write at positive `i > capacity` grows first, writes, and sets
  length to `i`.
- A nil write at positive `i > capacity` is an allocation-free no-op.
- A nil write in `length < i <= capacity` is an allocation-free no-op because
  that slot is already empty by invariant.
- A nil write at `i < length` creates/preserves an interior hole and does not
  change length.
- A nil write at `i == length` clears the slot and scans backward to the
  preceding non-nil slot or zero.
- Filling a hole below length leaves length unchanged.

Repeated `a[#a] = nil` normally examines one slot per removal. Deleting a tail
after earlier holes can require an O(n) backward scan. This is the deliberate
trade-off for O(1) `#a`.

### 2.3 Index rules and growth

Array reads and writes first classify the full `lua_Integer` index:

- a read at any `i < 1`, including `0`, `-1`, and `LUA_MININTEGER`, returns
  nil;
- a write at any `i < 1` raises a stable Array-index error;
- neither path performs a table lookup at key `0`;
- an out-of-capacity positive read returns nil;
- an out-of-capacity positive nil write is a no-op; and
- an out-of-capacity positive non-nil write grows or raises "array index too
  large" if no supported capacity can cover it.

Only after proving `i >= 1` may generated/runtime code convert to an unsigned
zero-based slot. This prevents signed-to-unsigned wrap and protects key `0`.

For a non-nil positive write that does not fit, grow to the smallest power of
two strictly greater than the logical Titan index. Out-of-capacity writes to
indices 1, 2, 3, 4, and 5 therefore select capacities 2, 4, 4, 8, and 8.
Constructor preallocation may use an exact non-power-of-two produced count. A
three-position constructor has capacity 3; a later write to index 4 grows it
to 8. Capacity does not shrink in this iteration.

Lua 5.5.0 keeps `MAXASIZE` private to `ltable.c`, so Titan cannot name that
macro from generated/runtime code. Mirror its exact pinned-5.5.0 formula in a
Titan-owned helper:

```text
min(2^(number of bits in int - 1),
    SIZE_MAX / (sizeof(Value) + 1))
```

Use the same internal `l_numbits`, `MAX_SIZET`, and cast conventions as the
pinned source, with compile-time assertions for the supported targets. Check
constructor counts and overflow-safe power-of-two growth against this bound
before converting to `unsigned` or calling `luaH_resize[array]`, so Titan can
raise its stable error rather than relying on Lua's generic "table overflow."
Test the bound arithmetic at equality and one-past without attempting a
maximum-sized allocation.

Every Array growth must:

1. save the authoritative logical length;
2. keep the Table and any collectable RHS in GC-scanned roots;
3. call `luaH_resizearray`;
4. restore the saved length immediately, because stock `luaH_resize` resets
   `*lenhint(t)` to `newasize / 2`;
5. restore any stack-derived C pointers after possible stack relocation; and
6. perform the requested store and final length transition.

`luaH_resizearray` preserves the logical one-node hash size and reinserts key
`0`; stock `luaH_resize` allocates a fresh hash vector, exchanges it, reinserts
the entry, and frees the old vector. Growth must assert/test that the proxy
backlink survives. Array stores must never use `luaH_setint` as a positive
hash fallback.

### 2.4 Array constructors

With no useful context, a positional constructor still defaults to Array:

```titan
local a = { 10, 20, 30 }       -- {integer}
```

The constructor remains an open expression-list consumer:

- expressions evaluate once, left to right;
- each fixed position is converted/checked before the next source expression,
  preserving side-effect and error order;
- non-final expressions and parenthesized calls contribute one value;
- a final fixed-multiple-return call contributes its visible fixed results;
- a statically flexible final call, a contextual call through `value`, or a
  trailing input `...` contributes its actual runtime-sized tail;
- discarded explicit expressions still execute;
- each produced result consumes one sequential logical position, including a
  nil accepted by the target type; and
- all prefix/open values stay rooted across allocation, conversion, resize,
  and stack relocation.

The constructor preallocates exact array capacity for the produced position
count and one hash node for the owner backlink. It writes the highest
non-nil produced position to `lenhint`; it does not blindly use the count:

```titan
local a: {value} = { 1, nil, 3 }  -- capacity 3, length 3
local b: {value} = { 1, 2, nil }  -- capacity 3, length 2
local c: {value} = { nil }        -- capacity 1, length 0
```

An explicit nil remains invalid for a non-option element type such as
`{integer}`. `{T?}` still normalizes to `{T}`. A dynamic nil converted to a
non-nil element type raises through ordinary conversion; a nil accepted by
`value` consumes its position and represents an absent slot.

### 2.5 Positional integer-Map constructors

In a context whose resolved type is exactly `Type.Map(Type.Integer, V)`, a
nonempty all-positional constructor builds an ordinary Lua Table:

```titan
local m: {integer: string} = { "a", "b", names() }
```

It uses the same open-demand rules as an Array constructor, coerces every
produced value to `V`, and assigns sequential keys `1..N`. A nil accepted by
`V` consumes a position but stores no Table entry. The ordinary Map array part
is preallocated to the static or actual produced count.

Classification rules:

- `{}` remains valid in any context-typed Map.
- A nonempty all-positional constructor is accepted only for an
  integer-keyed Map.
- `{[k] = v}` remains a keyed Map constructor; keys and values are scalar
  consumers.
- `{name = v}` remains record syntax and is an error in Map context.
- Positional/computed/named mixtures are deliberately rejected in this
  iteration.
- A trailing input `...` is accepted in an Array or positional integer-Map,
  but not in a keyed Map or record.
- A final call through `value` receives contextual type `() -> (...: V)`.

Use a representation-neutral checker annotation such as
`_positional_adjustment`; do not make the Map path depend on a name like
`_array_adjustment`.

### 2.6 Length operator

Generated Titan `#array` reads the authoritative hint directly:

```c
t->asize == 0 ? 0 : l_castU2S(*lenhint(t))
```

It must never call `luaH_getn` on an Array backing Table. With all new
invariants intact and an exact hint, stock `luaH_getn` would rediscover that
same valid border and write the same value. It is still the wrong operation:
it owns the word as a mutable search cache and, after any legacy/transiently
invalid state, may commit a different valid border instead of enforcing
Titan's explicit highest-present invariant. Lua's `#proxy` invokes `__len`,
which returns the guarded hint directly.

Extend `#` to a Map only when its resolved key type is exactly Titan
`integer`. Do not admit `value`, float, string, or foreign C integer key types
through compatibility.

For an integer-keyed Map, generated code uses:

```c
l_castU2S(luaH_getn(L, m))
```

That is Lua's raw table-border algorithm, not deterministic Array length and
not arbitrary `__len` metamethod dispatch. A holed Map's result remains an
unspecified valid Lua border.

### 2.7 Lua-visible proxy

One canonical, element-type-independent metatable per Lua state identifies
Titan Array proxies. Its `__name` and protected `__metatable` display are:

```text
Titan array metatable
```

It implements:

- `__index`: require an exactly integral numeric key; return nil immediately
  for `k < 1`; otherwise read only the positive array slot;
- `__newindex`: require an exactly integral numeric key; error immediately for
  `k < 1`; otherwise run the same growth/hole/length logic as Titan;
- `__len`: return the guarded authoritative hint; and
- no `__pairs` protocol.

The metatable is shared across element types, so Lua writes do not perform a
static element conversion. Titan validates/coerces the value when a typed read
later observes it.

When `__index` encounters a compiler-internal nested Array backing Table, it
returns that backing's canonical proxy. It returns an already boxed proxy or
any non-Array Lua value unchanged. This makes accessor-mediated Arrays
Lua-canonical without changing native nested-Array writes.

Ordinary Lua behavior:

- a Titan Array is table-like, but it is not a Lua table;
- `type(array) == "userdata"`;
- `rawget`, `rawset`, and `rawlen` reject the proxy because it is not a Table;
- applicable `table.*` functions operate through `__index`, `__newindex`, and
  `__len`;
- `ipairs` may use `__index` and stops at the first nil as usual;
- `pairs` support is not promised; and
- ordinary `getmetatable` sees the protected display value.

The debug library can bypass metatable protection and can expose/replace
uservalue 1. A C module can do likewise. Any such inspection or mutation,
including `rawlen`/`rawset` on the exposed backing Table, is undefined
behavior. The implementation must not carry a Lua patch or a complex
anti-debug protocol to make that misuse safe.

Boundary conversions are:

| From | To | Result |
| --- | --- | --- |
| Array | `value`/Lua | canonical proxy |
| Map | `value`/Lua | ordinary Table |
| `value` containing canonical proxy | Array | unwrap to backing Table |
| `value` containing plain Table | Array | runtime type error |
| `value` containing plain Table | Map | succeeds after Table check |
| `value` containing Array proxy | Map | runtime type error |
| Array | Map | statically rejected |
| Map | Array | statically rejected |

Round trips preserve identity: every backing Table has exactly one canonical
proxy and each proxy points to exactly one backing Table.

### 2.8 Standalone arguments

For `main(args: {string}): integer`, store command-line arguments from C
`argv[1]` onward at Titan indices `1..argc-1`.

- `#args == argc - 1`;
- `args[0] == nil`;
- the executable name is not stored in the Array; and
- both the direct main path and `titan.uv.bootstrap` observe the same logical
  contents.

`pmain` invokes the module's Lua entry wrapper in both branches: directly when
there is no bootstrap hook, or through `titan.uv.bootstrap`. It therefore
pushes the canonical proxy in both cases. The generated Lua entry wrapper
validates/unboxes that proxy and only then calls the exact native `main` with
the backing `Table *`.

## 3. Stock-Lua runtime protocol

### 3.1 Object construction

Provide one runtime constructor that returns a native backing `Table *` and
eagerly creates its canonical proxy. The required order is:

1. obtain/create the canonical per-state proxy metatable;
2. allocate a normal Table with `luaH_new` and root it on the Lua stack;
3. allocate a zero-payload, one-uservalue Udata and root it on the stack;
4. set the Udata metatable;
5. call `luaH_resize(L, t, initial_capacity, 1)` to request the initial array
   part and a logical one-node hash in one resize operation (stock Lua performs
   the hash-vector and array allocations separately inside that call);
6. initialize authoritative length to zero when `asize > 0`;
7. store the Table in proxy user value 1 and apply the ordinary Udata
   back-barrier;
8. insert `0 -> proxy` in the already-sized hash and apply the ordinary Table
   back-barrier;
9. set/restore the final constructor length after all element fills; and
10. publish/return only after both edges and all invariants are complete.

Both objects must remain in scanned stack slots across every allocation. A C
local pointer or `TValue` is not a GC root. Hard-memory/emergency collection
can occur during resize or insertion before a caller has applied a later
barrier.

For empty Arrays, `luaH_resize(L, t, 0, 1)` still creates the one-node hash;
length is defined as zero without touching `lenhint`.

### 3.2 Canonical metatable and module cache

Use an ordinary shared registry metatable, following Titan's existing
record/module publication style. The first creator installs the callbacks and
protection fields; later modules reuse the same Table pointer.

Install the callbacks as closures that capture the canonical metatable (or
otherwise recover it directly from the validated receiver), so nested-backing
probes inside `__index` do not query the registry. Setting the proxy's
metatable must use the ordinary Lua setter/object barrier while the proxy is
rooted.

Reserve one unconditional private Array-metatable slot in each generated
module after the importer-reconstructed public prefix and before other
module-private state. Initialize it during cold module initialization and
barrier the module Udata. Boundary checks use this cached pointer; normal
typed Array reads/writes do not load the module slot or query the registry.

Populate the slot immediately after the new module Udata is registry-anchored,
before import/global/record initialization and, in particular, before
`INITVARS`; module-variable initializers can construct or box Arrays. A
recovered module using this ABI contract already has the populated private slot. Test a
module-global Array initializer, repeated recovery, multiple providers, and
multiple Lua states.

Importers continue to reconstruct only the public exported-variable and
canonical-function-closure prefix. They do not compute or access this private
cache slot.

This cache is a normal ABI module-layout detail. It does not require a
runtime capability marker, patched-state sentinel, custom registry state
machine, or bootstrap preflight.

### 3.3 Backing/proxy validation

Runtime helpers must support required conversions in both directions and a
nonthrowing structural probe.

`require backing -> proxy` (the static type promises Array):

1. fetch integer key `0` from the hash;
2. require a full Udata;
3. require zero payload and exactly one user value;
4. require the cached canonical proxy metatable;
5. require user value 1 to be the same backing Table; and
6. require `length <= asize`.

`try backing -> proxy` (the caller is inspecting an arbitrary Table):

1. perform the same checks without raising;
2. return the canonical proxy on a complete match; and
3. return "not an Array backing" for an ordinary Map or any partial mismatch.

The nonthrowing form is required by the shared proxy `__index` and other
dynamic/value boxing paths: an ordinary Map Table is a legitimate value that
must pass through unchanged, not a malformed Array that should raise.

`proxy -> backing`:

1. require a full Udata with the cached canonical metatable;
2. require zero payload and exactly one user value;
3. require user value 1 to be a normal Table with no metatable;
4. require its integer key `0` to be the same Udata; and
5. require a valid guarded length.

Supported code never mutates either link. Boundary validation reports an
ordinary Titan type error for a plain Table or unrelated Udata. Corruption
performed through debug/C internals remains undefined behavior; helpers need
not recover from arbitrary forged headers or repair a broken cycle.

Table-to-proxy recovery may use the one-node hash directly after assertions or
`luaH_getint(t, 0)` in the initial implementation. Keep distinct helper names
for the nonthrowing probe and the required conversion. Both are boundary
operations, not part of the dense indexed hot path.

### 3.4 Length helpers and resize discipline

Add small internal helpers/macros in `titan-runtime/titan.h`/`titan.c` for:

- guarded length load;
- guarded length store;
- length-preserving `luaH_resizearray`;
- backing-to-proxy recovery;
- proxy-to-backing validation;
- positive read;
- positive set/delete; and
- proxy allocation/linking.

The length accessor must never dereference `lenhint` at `asize == 0`.
The setter must assert `length <= asize`.

Inventory every operation that can call `luaH_resize` or `luaH_resizearray`
for an Array. Constructor allocation may initialize a fresh hint. Every later
resize must save and restore it. No Array path may call `luaH_getn`,
`luaH_setint` for a user element, generic Table rehash, or a shrinking resize.

### 3.5 Barriers and rooting

All barriers are ordinary stock barriers:

- proxy uservalue 1 -> backing Table: barrier the Udata;
- backing key 0 -> proxy Udata: barrier the Table;
- backing Array slot -> collectable element: barrier the backing Table; and
- compiler-internal record/module/capture slot -> backing Table: use the
  existing owner-appropriate Udata/closure barrier.

The Array element hot path barriers `obj2gco(t)`, never the proxy.

Across a growth allocation, root:

- the backing Table;
- a collectable RHS;
- any open-result prefix/tail values; and
- any temporary proxy needed for boundary conversion.

After allocation, recompute stack-derived pointers before reading or writing
them.

### 3.6 Ordinary lifetime and freeing

No Titan free hook is required:

- the Table owns and frees its array block and one-node hash;
- the Udata owns and frees only its normal header/uservalue allocation;
- neither object has an Array finalizer;
- state close uses stock paths; and
- unreachable cycles are handled by the ordinary collector.

Runtime tests should prove this behavior under incremental and generational
GC and sanitizers, but the implementation must not add custom collector code.

## 4. Internal versus boxed representation

The compiler must distinguish two representations:

- `I(Array)`: compiler-owned typed/internal storage, represented by the
  backing `Table *` or a Table TValue;
- `B(Array)`: Lua-canonical boxed storage, represented by the proxy Udata or a
  Udata TValue.

The matrix is normative:

| Context | Array | Map | `Array?` | `value` containing Array |
| --- | --- | --- | --- | --- |
| Native local/exact arg/result | backing `Table *` | `Table *` | nil/raw backing TValue | proxy TValue |
| Typed spill/capture/module/record slot | raw backing Table TValue | Table TValue | nil/raw backing | proxy |
| Compiler-written Array element | raw backing | raw Map Table | nil/raw backing | proxy |
| Lua stack/generic call/export accessor | proxy Udata | ordinary Table | nil/proxy | proxy |
| Raw-visible Map key/value | proxy Udata | ordinary Table | nil/proxy | proxy |
| Exact variadic/flexible buffer | `Table **` | `Table **` | internal `TValue *` | boxed `TValue *` |

Consequences:

- `ctype(Type.Array)` remains `Table *`.
- `getslot`/`setslot` for statically Array-typed internal slots remain
  `hvalue`/`sethvalue`.
- Exact parameters, returns, out-parameters, and closure fast paths retain
  `Table *`; statically typed module slots store internal Table TValues.
- `TitanVargArrayOrMap` retains `Table **`.
- Array identity/equality compares backing pointers; proxy identity is
  equivalent because the mapping is one-to-one.
- Boxing an Array fetches its proxy from key `0`.
- Unboxing validates the proxy and returns its uservalue Table.
- `Option(Array)` needs distinct internal and boxed conversions; generic
  TValue copy helpers are insufficient.
- `value` always carries `B(Array)`, never a raw backing Table.
- Map keys and values are raw-visible to Lua, so every Array stored in a Map
  is boxed.
- Statically typed record/module slots must retain `I(Array)`; their
  Lua-facing getters box and setters unbox.
- Capture slots are compiler-internal (not accessor-mediated) and likewise
  retain `I(Array)`.

Nested Arrays require one mixed representation rule:

- a Titan write to `{ {T} }` stores the nested backing Table directly and
  barriers outer Table -> inner Table, preserving the hot path;
- Lua `__newindex` stores its incoming Lua-canonical value verbatim, so a
  nested Array written from Lua is a proxy;
- a typed nested-Array read accepts a validated raw backing fast path and a
  validated proxy slow path; and
- an `Array<value>` read must not automatically unwrap a proxy, because the
  proxy is the correct representation of that `value`.

This distinction must be explicit in helper names. A single polymorphic
`setwrapped`/`copyslotwrapped` operation may not silently choose between
internal and boxed storage. Conversion must dispatch on the semantic Titan
type and storage domain, not only on C type: Array and Map share `Table *`,
while Option, `value`, and Function all use `TValue`.

## 5. Checker and elaborated AST

### 5.1 Preserve the type schema

Keep `Type.Array(elem)` and `Type.Map(keys, values)` structurally unchanged.
Preserve:

- same-container-only equality/compatibility;
- `types.is_gc(Array) == true`;
- serialized `Array(...)` descriptors;
- optional indexed reads and nil-capable indexed lvalues;
- `value` as the gradual boundary; and
- variadic/flexible element validation.

Do not add Array-to-Map compatibility. The private backing is not a Map API.

### 5.2 Length checking

In the `Ast.ExpUnop` checker arm:

- preserve String and current fixed/countable C behavior;
- accept Array;
- accept Map only when the resolved key is exactly `Type.Integer`; and
- diagnose other Map key types as not integer-keyed.

Use exact resolved-type classification, not broad `types.compatible`.

### 5.3 Positional constructor adjustment

Refactor `Ast.ExpInitList` around one positional path:

1. classify empty/all-positional/all-computed/named/mixed fields;
2. derive Array element or integer-Map value context;
3. run `adjust_explist` exactly once;
4. coerce/check each fixed scalar and open tail exactly once;
5. preserve discards, open producer/count/type, and conversion annotations;
6. preserve source evaluation/error order; and
7. save the result as `_positional_adjustment`.

Preserve:

- no-context `{}` as the default empty `{integer}` Array;
- no-context `{nil}` as `Array(Nil)` with runtime length zero;
- first computed key selecting Map inference;
- first named field requiring record context;
- scalar keyed Map calls; and
- intentional diagnostics for every mixed field ordering.

Fix the existing Map-arm defects encountered by the refactor:

- a positional field must not reach `checkexp(false, ...)` and assert; and
- real computed keys/values must not skip `trycoerce`/`checkmatch`.

Avoid duplicate diagnostics for a bad positional scalar.

### 5.4 Context/result-demand coverage

Prove positional Array and integer-Map context through:

- typed local/module declarations;
- assignments;
- function arguments;
- return expressions;
- explicit casts; and
- contextual calls through `value`.

Preserve scalar earlier expressions, scalar parenthesized final calls, fixed
multiple returns, flexible returns, actual-count generic `LUA_MULTRET`,
trailing input `...`, per-position coercion, and discarded-expression
evaluation.

## 6. Code-generator work

Line numbers are not normative; follow helper names and elaborated
annotations as the file moves.

### 6.1 Split internal storage from Lua boxing

Audit every Array branch in:

- `ctype`;
- `getslot`/`setslot`;
- `getwrapped`/`setwrapped`/`copyslotwrapped`;
- `checkandget`/`checkandset`;
- option/value conversions;
- record/module field accessors;
- Array and Map element conversion;
- equality;
- exact and generic call wrappers;
- variadic/flexible input/output adapters; and
- standalone argument construction.

Keep native `Table *` helpers unchanged where they mean `I(Array)`. Add
explicitly named box/unbox helpers where a Lua-canonical `TValue` is required.
Do not globally change Array's TValue tag from Table to Udata.

Pin generated-C tests that no exact Array signature becomes `Udata *` and no
Array descriptor becomes `Udata **`.

### 6.2 Module metatable cache

Extend `allocate_upvalues` with one unconditional private Array-metatable
cache slot after:

1. exported module variables; and
2. canonical exported function closures.

Place it before other private slots. Initialize/cache it in the normal module
initialization path, using the shared runtime metatable and a module-Udata
back-barrier. Imported and recovered modules must agree on the same ABI
layout.

Only boxing/unboxing and proxy construction use this slot. Dense typed reads
and writes do not.

### 6.3 Array assignment

Rewrite the Array `Ast.VarBracket` lowering around native `Table *`:

1. evaluate Array, index, and RHS once in source order;
2. keep backing Table and collectable RHS in scanned roots;
3. reject `k < 1` before unsigned conversion or Table mutation;
4. for nil beyond capacity, do nothing;
5. for non-nil beyond capacity, compute/validate the new capacity;
6. save length, resize, restore length, and refresh relocated pointers;
7. store directly with `obj2arr`;
8. barrier the backing Table for collectable values; and
9. perform the length raise/backscan transition.

The common in-capacity GC-valued case must compile to the direct store plus
Table barrier, with no proxy/uservalue/backing load. Do not call
`luaH_setint` for any user Array index.

Failed writes at `0`/negative indices must preserve key `0`, capacity, length,
and all positive elements.

### 6.4 Array reads and recursive Option conversion

Adapt `codeindexarray`:

- start from native `Table *`;
- branch `k < 1` to nil before any Table lookup;
- convert to a zero-based unsigned slot only after that branch;
- read only when `slot < asize`;
- return nil otherwise; and
- perform no hash lookup, allocation, registry lookup, or length scan.

An indexed read's static result is `Option(T)`, not bare `T`. Make recursive
Option conversion normative:

- an absent/empty/nil slot produces an internal nil `TValue`;
- for `Option(Array)`, a validated raw backing Table becomes an internal Table
  TValue, while a canonical proxy is validated/unwrapped and then becomes an
  internal Table TValue;
- for `Option(value)`, use the nonthrowing backing probe so an internal Array
  becomes its proxy while an ordinary Map Table passes through;
- for `Option(Map)`, accept an ordinary Table and reject an Array proxy; and
- when an `Option(Array)` later crosses a boxed boundary, convert nil to nil
  and its internal backing Table to the canonical proxy.

Apply the same recursive converter to `codeindexarray` and `codeindexmap`.
This avoids ever applying `hvalue` directly to a proxy read from a raw-visible
Map or Lua-mutated Array.

After the option layer, element conversion follows the same base-type rules:

- expected Array: accept a validated internal backing Table fast path or a
  canonical proxy slow path;
- expected `value`: use the nonthrowing backing probe; box a matching internal
  Array, pass an ordinary Map Table through unchanged, and retain an existing
  proxy as a proxy;
- expected Map: accept an ordinary Table, not an Array proxy; and
- other types: preserve existing checked conversion.

The shared proxy `__index` uses the nonthrowing structural probe to box a
nested internal Array before returning to Lua and to pass an ordinary nested
Map through unchanged.

### 6.5 Dense Array constructor

Refactor `codearray` without weakening its open-result/rooting machinery:

1. materialize/root fixed and open values exactly once in source order,
   completing each fixed position's conversion/check before evaluating the
   next source expression and converting an open run after its one producer
   returns;
2. compute the actual produced position count;
3. validate that exact capacity is representable;
4. allocate/root the backing Table and canonical proxy;
5. allocate exact capacity plus the one-node hash and install both cycle
   edges;
6. restore stack pointers after allocations;
7. copy typed internal values to positive array slots with `obj2arr`;
8. barrier the backing Table for collectable entries;
9. determine the highest non-nil produced position; and
10. store that final value in `lenhint` when `asize > 0`.

For `Array<Array>`, copy the inner backing Table. For `Array<value>`, copy the
canonical proxy contained by `value`. Do not use one representation-blind copy
path.

### 6.6 Positional integer-Map constructor

Split keyed and positional Map code generation by the elaborated annotation.

The positional path shares a representation-neutral expression-run
materializer with Array construction, but:

- allocates an ordinary raw-visible Table;
- preallocates its array part to the produced count;
- stores positions at keys `1..N`;
- has no explicit deterministic length; and
- boxes every Array key/value before placing it in the Map.

This boxing requirement applies to keyed Maps and positional
`{integer: Array}` Maps. A raw Array backing Table must never enter a Map.

Audit ordinary Map bracket operations as well:

- an Array-typed Map key is boxed before lookup, update, or insertion, so the
  same proxy identity is used in every operation;
- an Array-typed Map value is boxed before a write;
- an Array-valued Map read recursively converts `Option(Array)`, unboxing a
  stored proxy to the internal nil-or-backing representation; and
- `value` keys/values already contain canonical proxies and must not be
  unwrapped merely because their runtime value is an Array.

### 6.7 Length lowering

In `codeunaryop`:

- Array: guarded direct `lenhint`;
- integer-keyed Map: `l_castU2S(luaH_getn(L, map))`;
- String and existing C cases: unchanged.

Add generated-C assertions that Array length never calls `luaH_getn`.

### 6.8 Calls, options, variadics, and flexible returns

Exact/native Array paths remain raw:

- argument/result/local/out type: `Table *`;
- exact variadic/flexible element buffer: `Table **`;
- descriptor family: `TitanVargArrayOrMap`.

Lua-stack/generic adapters box each outgoing Array and unbox each incoming
canonical proxy. Apply the distinction to:

- exact versus generic first-class function calls;
- Lua entry wrappers;
- dynamic `value` calls;
- flexible output buffers;
- variadic input buffers;
- options containing Arrays; and
- multi-result adjustment/copy code.

Dispatch these adapters from the semantic Titan type, recursively through
Option, rather than from the shared C descriptor family. In particular,
`TitanVargArrayOrMap` cannot say whether a `Table **` element is an Array that
needs boxing or a Map that must stay a Table, and a `TValue *` descriptor
cannot distinguish Option(Array), `value`, and Function.

For a call edge whose semantic formal/result type is Array, an exact caller and
callee exchange backing pointers and a generic wrapper pays the proxy
lookup/validation cost. Boxing can still occur inside an otherwise exact call
when the declared type is `value`, and at raw-Map stores or Lua accessors;
those are boxed storage boundaries, not Array-typed exact call edges.

### 6.9 Standalone `main`

Construct the ordinary backing/proxy pair, store `argv[1..argc-1]` in positive
slots, and set length to `argc - 1`.

- Never write index `0`; it already contains the proxy backlink.
- `pmain` pushes the proxy in both its no-hook and bootstrap-hook branches.
- The module's Lua entry wrapper unboxes it and calls exact native `main` with
  the backing `Table *`.
- Both routes observe `args[0] == nil`.

## 7. ABI and installation boundary

### 7.1 Why this is an ABI break

Keep the exact physical Array signatures as `Table *`/`Table **`, but advance
the compiled-module ABI. Generated code from before and after the boundary
cannot safely share Array values because pre-boundary code may:

- treat `lenhint` as a mutable border cache: old writes/resizes can first
  violate the new dense invariant, after which old `#`/`luaH_getn` can commit a
  different border as the supposed length;
- resize without restoring the explicit `lenhint`;
- read/write key `0`, exposing or destroying the canonical proxy;
- preserve negative keys contrary to the new semantics;
- place high positive indices in the hash;
- accept or expose a raw Table at Lua/`value` boundaries.

The serialized `Array(...)` type text and exact pointer width are unchanged;
the ABI gate protects the representation invariants and boundary protocol, not
a C pointer-size change.

Update the ABI rationale in `titan-runtime/titan.h` with this exact explanation.
The authoritative split keeps the identities independent:

```text
TITAN_ABI_VERSION     = "<active-ABI>"
TITAN_VERSION         = "<semantic-version>"
TITAN_LIBRARY_VERSION = "<major>.<minor>"
TITAN_PATH_<major>_<minor>
```

Do not claim a `Table * -> Udata *` or `Table ** -> Udata **` migration.

### 7.2 Version inventory

Update live version/path/environment references in at least:

- `titan-compiler/driver.lua`;
- `titan-runtime/titan.h`;
- `Makefile`;
- `scripts/stdlib_installer.lua`;
- `.github/workflows/ci.yml`;
- `spec/abi_spec.lua`;
- driver/static metadata/compiler/provider/rockspec/installer specs;
- `spec/support/ci_abi_migration_smoke.sh`;
- `spec/support/ci_stdlib_snapshot.sh`;
- `spec/support/ci_libuv_mode_smoke.sh`;
- async/stdlib support helpers;
- README, AGENTS, and both manuals; and
- fixtures/comments that make stale ABI claims.

Finish with an audit for stale conflated names and numbered paths:

```sh
rg -n 'TITAN_|lib/titan/' \
  titan-compiler titan-runtime spec scripts doc Makefile README.md AGENTS.md \
  .github/workflows
```

Classify remaining hits as current split-version references or errors.

### 7.3 Providers, installer, and clean-prefix smoke

Publish the active standard artifacts at:

```text
$ROCKS_TREE/lib/titan/<library-version>/{titan.so,titan.a}
$ROCKS_TREE/share/lua/5.5/titan/{coroutine,uv,async,timer,fs,net,os}.lua
```

Rebuild all seven logical standard modules because generated module layout and
Array boundary helpers change even if an individual serialized interface does
not mention Array.

Providers reject pre-boundary compiled dependencies through the existing ABI
protocol; installer rollback must continue to restore the exact predecessor
pair/shims/dSYM. Use a fresh disposable prefix to prove `package.cpath` selects
the active library layout, bare `require "titan"` selects the active
provider, and a focused synthetic mismatch is rejected before metadata use.
Do not add cross-version migration machinery.

Retain the current Linux producer/consumer topology and its prepared-prefix
artifact contract. Do not add a frozen predecessor checkout, a patched-Lua
control tree, or a second prefix/control tar solely for this feature.

### 7.4 Stock Lua remains the prerequisite

`make lua` continues to install pinned, configured, otherwise stock Lua 5.5.0
and matching internal sources/archive. This feature adds no:

- Lua patch file;
- edits to `ltable.*`, `lgc.c`, `lapi.c`, `lstate.*`, or `ltm.h`;
- extraction-patch stamp;
- capability marker;
- link-time protocol symbol;
- patched-state registry sentinel;
- bootstrap capability preflight; or
- stock-Lua rejection test.

`lua ~> 5.5` remains the LuaRocks dependency. Titan remains tied to the exact
5.5.0 internal layout through `lenhint`, `obj2arr`, and related headers, which
is permitted by the feature constraints.

## 8. Test plan

Create/retain topical suites:

```text
spec/dense_array_runtime_spec.lua
spec/checker/dense_arrays_spec.lua
spec/coder/dense_arrays_spec.lua
```

The runtime suite is a focused stock-internals proof. Add it explicitly to
`spec/support/ci_test_groups.sh`'s existing `library_serial_tests` list,
broadening that list's comment/labels/counts to cover serial native/runtime
tests. Run it in the producer's serial non-LuaCov shard before compiler
coverage; compiler/language behavior remains in checker/coder coverage. Use
unique temporary build paths and do not clean Make-owned shared
runtime/stdlib artifacts.

### 8.1 Checker tests

Cover:

- Array/Map type distinction and rejected direct casts;
- optional Array reads and legal nil writes;
- no-context positional Array construction;
- contextual positional integer-Map construction;
- empty non-integer Map construction;
- rejection of nonempty positional non-integer Maps;
- mixed positional/computed/named diagnostics without assertions;
- computed Map key and value coercion/checking;
- one diagnostic per invalid positional value;
- fixed/flexible/value/variadic final-result adjustment;
- scalar earlier and parenthesized calls;
- scalar keyed Map values;
- contextual propagation through declarations/assignments/returns/calls/casts;
- explicit nil rules for `{integer}` versus `{value}`;
- `#` on Array and exact integer-keyed Map aliases; and
- rejection of other Map key types.

### 8.2 Dense Array behavior

Cover:

- empty Array: `asize == 0`, logical length zero, one owner hash entry;
- exact constructor capacities;
- growth boundaries at indices 1, 2, 3, 4, and 5;
- saved/restored length across every resize;
- key-0 proxy survival across repeated resizes;
- interior deletion versus tail backscan;
- repeated pop to zero;
- filling interior/tail holes;
- nil beyond capacity as no-op;
- high representable positive writes;
- oversized non-nil positive error before truncation/hash fallback;
- reads at 0, negative values, and `LUA_MININTEGER` returning nil;
- writes at those indices raising without changing any invariant;
- no positive or negative user entries in the hash;
- `{value}` interior/trailing/all-nil and open-tail behavior;
- fixed/multireturn/flexible/value/variadic production;
- deterministic highest-present-positive `#Array`; and
- capacity remaining unobservable in Titan source.

Rewrite existing representation-dependent fixtures, not only new topical
tests. Inventory at least `spec/coder/coder_spec.lua` cases that pass a plain
Lua Table to Array-typed Titan code: obtain an Array from a Titan factory and
retain paired plain-Table rejection/Map-acceptance assertions. Replace the
old Lua-border design pin in `spec/coder/variadic_spec.lua`: `#...` still
counts argument slots, while `#{...}` uses highest-present-positive Array
length for nil-containing runs.

Where capacity/hash/hint state matters, inspect generated C or use the focused
internal runtime harness rather than adding a public API.

### 8.3 Lua interoperation and boxing

From Lua, verify:

- `type(array) == "userdata"`;
- protected `"Titan array metatable"`;
- integral `__index`/`__newindex`;
- fractional/nonnumeric index errors;
- reads below 1 return nil and writes below 1 error;
- `#proxy` matches Titan `#array`;
- nil holes and tail deletion share Titan semantics;
- wrong element types written from Lua fail on a later typed read;
- `rawget`/`rawset`/`rawlen` reject the proxy, while applicable `table.*`
  functions operate through its ordinary callbacks;
- `ipairs` stops at the first nil;
- plain Lua Table is rejected as Array and accepted as Map; and
- one proxy identity survives repeated Lua/value/module round trips.

Do not test debug forgery, uservalue hiding, or recovery after debug/C
corruption. Document that boundary as undefined instead.

Explicit nested cases:

- `Array<Array>` written by Titan (raw backing element);
- `Array<Array>` written by Lua (proxy element);
- `Array<value>` containing an Array proxy without unwanted unboxing;
- `Array<value>` containing an ordinary Map—including one with an unrelated
  key-0 value—passing through the nonthrowing backing probe unchanged;
- `Map<integer, Array>` storing only proxies;
- `Map<Array, V>` key identity through proxies;
- Array fields in records/modules/accessors; and
- `Option(Array)` across exact and generic boundaries.

Also cover identity equality where the type permits it: typed Arrays compare
by backing identity, a `value` round trip compares the same canonical proxy,
and `Option(Array)` preserves identity through nil-or-backing conversion.

### 8.4 Integer-Map behavior

Cover:

- fixed and runtime-open positional constructors;
- sequential positions across nil in `{integer: value}`;
- non-value conversion error;
- array-part preallocation;
- coercion/error side-effect order;
- scalar keyed fields;
- Array keys/values boxed before raw Map storage;
- raw Lua Table inputs/casts;
- contiguous `#m`;
- holed `#m` asserted only as a valid Lua border; and
- a Table `__len` metamethod proving Titan Map length uses `luaH_getn`.

### 8.5 GC, barriers, and lifetime

Exercise incremental and generational modes:

- proxy-only root keeps backing/elements alive;
- a backing Table held by a GC-scanned native/internal owner keeps the proxy
  alive (a raw C local alone is deliberately not counted as a root);
- unreachable proxy/Table cycle is collected;
- Array is sole owner of strings, Maps, records, nested Arrays, closures, and
  `value`s;
- old backing Table -> young collectable element mutation;
- both construction edges have correct barriers;
- key-0 owner survives resize/rehash reinsertion;
- constructor/open-run values survive allocation and stack relocation;
- Arrays in globals, records, imports, exact calls, variadics/flexible returns,
  and Lua round trips;
- repeated allocate/grow/drop/full-collect reaches a stable memory envelope;
- ordinary state close frees both objects and Table storage; and
- ASan/UBSan/leak checks find no use-after-free, lost barrier, or leak.

Keep a small dense cycle/resize/barrier case in the sanitizer job. Remove all
tests for embedded-header colors, custom accounting/freeing, interior frees,
special finalization, or patched collector behavior.

### 8.6 Cross-module and generated ABI

Test Arrays through:

- two source modules;
- separate `.so` providers;
- selected `.a` providers;
- shared prefix-container providers;
- exact first-class calls;
- generic `value` calls;
- variadic Array parameters; and
- flexible Array returns.

Pair Array descriptor cases with generic variadic/flexible Map cases, and with
`Option(Array)` through TValue variadic/flexible paths where the language
supports them. These cases must prove dispatch follows the semantic Titan type
rather than the shared `Table **` or `TValue *` descriptor.

Generated-C assertions must prove:

- exact signatures use `Table *`;
- descriptors use `Table **`;
- typed slots store backing Tables;
- Lua/value/Map boundaries use proxies;
- hot Array writes barrier the backing Table;
- reads/writes guard `k < 1` before any lookup/store;
- no Array length path calls `luaH_getn`;
- every post-construction Array resize restores `lenhint`; and
- no operation queries the registry for an Array tag;
- outer slot addressing and the common typed write perform no
  metatable/uservalue load; and
- the post-load conversion for an Array-typed nested element is the explicit
  structural-validation exception.

Add focused synthetic DSO/static ABI-mismatch coverage even though serialized
Array type text is unchanged.

### 8.7 Standalone and standard library

For direct and `titan.uv.bootstrap` main paths, prove:

- positive arguments occupy `1..n`;
- `#args == n`;
- `args[0] == nil`;
- no-argument behavior; and
- both `pmain` branches pass the proxy to a Lua entry boundary, whose wrapper
  unboxes before the exact native `main` call.

Update the seven-module bundled/system stdlib smokes, async helpers, and
snapshot/restore paths for the active library namespace and ABI-sensitive
caches without moving library behavior under LuaCov.

### 8.8 Build, installer, and CI

Update:

- `spec/abi_spec.lua`;
- `spec/libuv_build_spec.lua`;
- driver/static-provider specs;
- `spec/rockspec_spec.lua`;
- `spec/stdlib_installer_spec.lua`;
- `spec/support/ci_abi_migration_smoke.sh`;
- `spec/support/ci_stdlib_snapshot.sh`;
- `spec/support/ci_libuv_mode_smoke.sh`; and
- `.github/workflows/ci.yml`.

Prove fresh and warm stock-Lua prefixes, active library-path selection, clean
installation, rollback, bundled/system providers, and bare support loading. Do
not add patch/capability/source-rejection cases.

## 9. Documentation plan

This is a user-visible feature; both manuals change in the same delivery.

### 9.1 Language manual

Rewrite the canonical `doc/language/arrays-maps.md` and refresh its index
entry. Document:

- Array versus Map;
- positive-only Array indexing;
- holes and highest-present-positive length;
- integer-Map border length;
- growth and oversized-index errors;
- positional constructors/open tails;
- Lua-visible userdata proxy versus ordinary Map Table;
- cast/interoperation matrix;
- raw/table-library behavior;
- debug/C undefined-behavior boundary; and
- performance/complexity.

Cross-update at least:

- `doc/language/lua-interop.md`;
- `doc/language/types.md`;
- `doc/language/option-types.md`;
- `doc/language/expressions.md`;
- `doc/language/functions.md`;
- `doc/language/modules.md`;
- `doc/language/grammar.md`;
- `doc/language/variadic-parameters.md`;
- `doc/language/flexible-returns.md`;
- `doc/language/multi-module-libraries.md`;
- `doc/language/static-compiled-modules.md`;
- `doc/language/philosophy.md`;
- `doc/language/index.md`; and
- README.

Replace all `args[0]` promises with positive-only standalone arguments.

### 9.2 Implementation manual

Add and index:

```text
doc/implementation/dense-arrays.md
```

Document:

- ordinary backing Table and canonical proxy Udata;
- key-0/uservalue strong cycle;
- stock GC ownership and barriers;
- authoritative `lenhint`;
- resize restoration;
- internal `I(Array)` versus boxed `B(Array)`;
- nested Array and raw-Map rules;
- metatable/module cache;
- checker positional elaboration;
- read/write/constructor/length lowering;
- exact versus generic calls;
- ABI semantic break; and
- failure/performance boundaries.

Cross-update:

- `doc/implementation/values-and-gc.md`;
- `doc/implementation/codegen-overview.md`;
- `doc/implementation/codegen-constructs.md`;
- `doc/implementation/lua-interop-internals.md`;
- `doc/implementation/checker.md`;
- `doc/implementation/variadic-parameters.md`;
- `doc/implementation/flexible-returns.md`;
- `doc/implementation/folder-modules.md`;
- `doc/implementation/driver.md`;
- `doc/implementation/multi-module-libraries.md`;
- `doc/implementation/static-compiled-modules.md`;
- `doc/implementation/error-handling.md`;
- `doc/implementation/libuv-runtime.md`;
- `doc/implementation/coroutines.md`;
- `doc/implementation/index.md`;
- `doc/lua-5.5-migration.md`;
- `doc/variadic-parameters.md` if retained; and
- `doc/async-with-coroutines.md`.

The Lua migration document should explain Titan's new use of stock 5.5
`lenhint`; it must not claim a Lua patch.

### 9.3 Repository guidance

After implementation is proven, update `AGENTS.md`/the current guidance bridge
with:

- native Table versus Lua proxy representation;
- key `0` and positive-only indexing;
- explicit-length/resize invariant;
- Table element barriers and rooting;
- internal-versus-boxed conversion rule;
- unchanged `Table **` descriptors;
- active ABI and library paths;
- positive-only standalone args; and
- topical specs/sanitizer/CI placement.

## 10. Phased implementation sequence

### Phase 1 — stock representation proof

1. Inventory every stock-5.5 writer of `lenhint` used by Titan.
2. Prototype ordinary Table/proxy allocation with key `0` and uservalue 1.
3. Prove one-node hash preservation across `luaH_resizearray`.
4. Prove saved/restored hint behavior.
5. Prove proxy-only, backing-only, and unreachable-cycle GC cases in both
   collector modes.

Exit criterion: the two-object stock-Lua ownership/length protocol has focused
native evidence and no Lua patch is required.

### Phase 2 — isolated runtime primitives

1. Add Table-based allocation/length/reserve/get/set helpers.
2. Add canonical proxy metatable and callbacks.
3. Add both-direction structural validation and barriers.
4. Land the focused native runtime and sanitizer cases.

Do not wire these helpers into generated modules before the atomic cutover.

Exit criterion: the isolated runtime harness preserves key `0`, explicit
length, growth, Lua callbacks, barriers, and normal collection without
changing generated module layout or behavior.

### Phase 3 — atomic Array ABI cutover

Land the following as one coherent cutover; no tested/published intermediate
compiler may advertise the old ABI marker with the new cache, or box an old constructor's
ownerless Table:

1. bump ABI constants, metadata, and ABI-sensitive cache namespaces while
   keeping semantic-release and library-path constants independent; update the
   live Make/rockspec/installer constants needed for a coherent first install;
2. add and initialize the private module metatable cache before `INITVARS`;
3. rewrite every Array constructor, including standalone argv, to create the
   complete backing/proxy pair;
4. replace reads, writes, growth, deletion, and `#` with the new invariants;
5. introduce explicit internal/boxed conversion helpers;
6. keep native `Table *`/`Table **`;
7. audit value/options/records/modules/Maps/calls/variadics/flexible returns;
8. migrate existing plain-Table Array fixtures and the variadic Lua-border
   design pin; and
9. add nested/exact/generic/generated-C and synthetic ABI-mismatch tests.

Exit criterion: every constructed Array has its owner cycle, no raw backing
escapes a Lua/value/Map boundary, and no proxy load appears in the common
typed write or outer slot-addressing path.

### Phase 4 — Array hardening and full behavior coverage

1. Complete boundary/rooting/error-order stress cases.
2. Pin maximum-capacity arithmetic and every growth boundary.
3. Complete Lua interop, nested I/B, GC, provider, and standalone tests.
4. Run the focused sanitizer case and generated-C audit.

Exit criterion: every normative Array semantic, lifetime, boundary, and
performance invariant has direct evidence.

### Phase 5 — integer-Map/checker work

1. Generalize `_array_adjustment` to `_positional_adjustment`.
2. Add positional integer-Map checking/codegen.
3. Fix keyed Map checking and duplicate Array diagnostics.
4. Box Array Map keys/values.
5. Add exact-integer Map `#`.

Exit criterion: Array and positional Map share result-demand semantics without
sharing representation or length rules.

### Phase 6 — standalone, packaging, and stdlib

1. Exercise the already-cut-over positive-only argv representation in the
   production direct/bootstrap paths.
2. Complete ABI rollback, clean-install, CI, SDK, and provider-path coverage
   beyond the live cutover already required by Phase 3.
3. Update installer rollback and shims.
4. Replace the configured-prefix migration smoke with a clean-prefix selection smoke.
5. Run DSO/archive and bundled/system stdlib gates.

Exit criterion: production artifacts are coherent same-ABI pairs, pre-boundary
fixtures are rejected, and both main routes see the canonical logical Array.

### Phase 7 — manuals and guidance

1. Update and cross-link the language manual.
2. Add/index the implementation chapter and update affected chapters.
3. Update README and repository guidance from proven behavior.
4. Search for stale table-equivalence, `args[0]`, `luaH_getn(Array)`,
   Udata-native, embedded-Table, patched-Lua, and stale ABI claims.

Exit criterion: user and implementer documentation fully describes the shipped
model.

### Phase 8 — full validation and adversarial review

1. Reinstall the edited compiler before Busted runs.
2. Run focused runtime/checker/coder/ABI/packaging tests.
3. Run library/serial groups before compiler coverage, then `make test`.
4. Run sanitizer and fresh-prefix evidence.
5. Review generated C against the direct-hot-path and I/B matrix.
6. Review the feature brief line by line against tests/docs.
7. Require green Linux push CI. The maintainer waived the manual complete
   macOS dispatch for this delivery.

Exit criterion: all acceptance items have evidence and no high/medium review
issue remains.

## 11. Validation commands and CI evidence

Use a distinct absolute isolated prefix:

```sh
export PREFIX=/tmp/titan-$USER-dense-array
export ROCKS_TREE="$PREFIX"
export PATH="$PREFIX/bin:$PATH"

make lua
make luarocks
make libuv
"$PREFIX/bin/luarocks" make

busted spec/dense_array_runtime_spec.lua
busted spec/checker/dense_arrays_spec.lua
busted spec/coder/dense_arrays_spec.lua
busted spec/abi_spec.lua
busted spec/libuv_build_spec.lua
busted spec/rockspec_spec.lua
busted spec/stdlib_installer_spec.lua
busted spec/stdlib/uv_bootstrap_spec.lua

bash spec/support/ci_test_groups.sh libraries
bash spec/support/ci_test_groups.sh compiler
make test
```

Run the focused sanitizer configuration with the normal
Table/proxy/cycle/resize/barrier case. The repository's general post-Linux
macOS command remains:

```sh
gh workflow run ci.yml --ref <branch>
```

The maintainer explicitly waived that manual dispatch for this delivery.

## 12. Acceptance criteria

### Representation and ownership

- [x] Native/exact Array values remain backing `Table *`.
- [x] Each backing has exactly one zero-payload/one-uservalue proxy Udata.
- [x] Proxy uservalue 1 points to the backing; backing hash key `0` points to
      that proxy.
- [x] The backing hash contains no user keys and positive values never fall
      back to it.
- [x] `asize == 0` means length zero; otherwise `lenhint` is authoritative.
- [x] Resize preserves key `0` and restores saved length.
- [x] Stock incremental/generational GC traces and collects the normal cycle.
- [x] Element barriers target the backing Table.
- [x] No Lua source patch, custom GC traversal/free, finalizer, or registry
      owner map exists.

### Semantics

- [x] `#Array` is O(1) and equals the greatest present positive index.
- [x] Interior holes do not shorten length; tail deletion backscans.
- [x] Reads at every index `< 1` return nil before lookup.
- [x] Writes at every index `< 1` error before mutation.
- [x] Positive growth uses the specified strictly-greater power-of-two rule.
- [x] Nil beyond capacity does not allocate; oversized non-nil writes fail.
- [x] Fixed/open constructors preallocate produced count and record the last
      non-nil position.
- [x] Positional integer-Maps remain ordinary Tables with Lua-border length.
- [x] Plain Lua Tables fail Array checks and remain valid Maps.
- [x] Standalone args occupy only positive indices and `args[0] == nil`.

### Performance and boundaries

- [x] Common typed Array read starts directly from `Table *`.
- [x] Common GC-valued typed write is direct `obj2arr` plus Table barrier.
- [x] Outer slot addressing and the common typed write load no
      proxy/uservalue/metatable/registry entry; nested Array element
      validation is an explicit post-load exception and still avoids the
      registry.
- [x] Internal slots/exact calls use backing Tables.
- [x] Lua/value/raw-Map boundaries use canonical proxies.
- [x] Nested Arrays and `Option(Array)` obey the I/B matrix.
- [x] Exact variadic/flexible descriptors remain `Table **`.
- [x] Debug/C mutation of private internals is documented as undefined.

### ABI and delivery

- [x] ABI rationale cites semantic/boundary/invariant incompatibility,
      not a false pointer-layout change.
- [x] Active paths/providers/shims/install/rollback are complete.
- [x] Pre-boundary fixtures are rejected as dependencies.
- [x] Focused runtime/checker/coder/cross-provider/standalone/packaging tests
      pass in their correct shards.
- [x] Sanitizer and full `make test` pass.
- [x] Exact-head Linux CI passes.
- [x] Manual macOS CI is waived by the maintainer for this delivery.
- [x] Both manuals, README, and repository guidance are current.

## 13. Adversarial review checklist

### Semantic reviewer

- Map each feature-brief statement to plan semantics and a named test.
- Look for any read path that can reveal key `0`.
- Look for any write path that can destroy key `0`.
- Verify holes, trailing nil, oversized indices, empty constructors, and
  positive-only standalone args.
- Keep deterministic Array length separate from Map border length.

### Runtime/GC reviewer

- Trace Table and Udata roots across every allocation before the cycle closes.
- Trace both cycle-edge barriers and old Table -> young element barriers.
- Verify the hash remains one node with key `0` after every resize.
- Verify every resize restores `lenhint` and no Array path calls `luaH_getn`.
- Prove proxy-only, backing-only, unreachable-cycle, and state-close behavior
  using stock Lua.
- Reject embedded headers, custom collector code, and finalizer ownership.

### Compiler/ABI reviewer

- Classify every Array storage/copy as internal `I` or boxed `B`.
- Inspect value, Option, nested Array, Map, record/module, accessor, generic
  call, variadic, and flexible paths.
- Confirm exact `Table *`/`Table **` signatures.
- Inspect generated hot writes for direct Table barriers and no extra backing
  load.
- Confirm guards precede unsigned conversion and any hash lookup/store.
- Inventory every stale ABI reference and installed artifact.

### Documentation/test reviewer

- Search for stale `"arrays are tables"`, `args[0]`, Array `luaH_getn`,
  `TitanArray`, Array `Udata *`, `Udata **`, embedded Table, patched Lua,
  capability marker, and hidden-uservalue claims.
- Confirm tests do not pass plain Lua Tables as Arrays.
- Confirm debug/C misuse is not accidentally promised safe.
- Keep native runtime/library behavior outside LuaCov and compiler semantics
  inside the compiler shard.
- Confirm the maintainer's macOS-dispatch waiver is recorded after green
  exact-head Linux and review.
