# Dense Arrays

Titan ABI 0.17 introduced `Type.Array(T)`'s deterministic, positive-only
dense backing while preserving its native C representation as `Table *`.
ABI 0.20 kept that hot representation and one shared proxy metatable, but
added a construction-selected Lua writer as the proxy's second traced user
value. ABI 0.21 retained that representation while advancing the embedded
Lua contract to 5.5.1, and ABIs 0.22 through 0.25 retained it. ABI 0.26 changes
the semantic constructor to `Type.Array(T, isconst)` and adds a distinct const
proxy tag while keeping `Table *` for both exact native forms. Typed Titan reads
are strict. Only mutable proxies provide `__newindex`; their non-nil Lua writes
run the writer's target-directed dynamic coercion before mutation.

This chapter describes the runtime protocol, checker elaboration, generated-C
lowering, GC rules, and ABI boundary. Language-visible behavior is specified
in [Arrays and maps](../language/arrays-maps.md).

## Representation contract

An Array consists of two ordinary stock-Lua objects:

1. a normal `Table` used as the exact/native backing; and
2. a zero-payload full `Udata` used as the canonical boxed proxy.

The backing and proxy form a strong cycle. The proxy's second user value carries
the writer policy only for a mutable Array:

```text
backing Table hash key 0 ───────────────► proxy Udata
          ▲                                  │
          └──────────── user value 1 ◄───────┤
                                             └── user value 2 ──► writer CClosure ──► _mod
                                                              or nil for const
```

The proxy has exactly two user values and one of two canonical per-state
metatables. User value 1 (C user-value index 0) is the backing. Mutable user
value 2 (index 1) is the module-local writer closure selected by the Array's
final construction element type; const user value 2 is nil. The metatable—not
the writer—is the exact mutable/const tag. The writer is behavior for genuine
Lua writes, not proof of current contents. The backing table has no metatable.
Integer key 0 is private and is the table's only live hash entry; every user
position is a positive index in the array part.

For backing table `t`:

```c
capacity(t) = t->asize;
length(t)   = t->asize == 0 ? 0 : *lenhint(t);
```

The maintained invariants are:

- `0 <= length <= capacity`;
- every slot in `[length, capacity)` is empty;
- when `length > 0`, slot `length - 1` is non-nil;
- lower slots may be holes;
- no positive or negative user index is stored in the hash;
- hash key 0 points to the canonical proxy;
- proxy user value 1 points to the same backing; and
- proxy user value 2 contains the constructing module's writer closure for a
  mutable Array and nil for a const Array;
- the backing has no metatable.

Logical length is therefore the highest present positive index, not an element
count and not whichever valid border Lua's table-length search happens to
choose.

## Runtime construction

`titan_array_new(L, metatable, capacity, writer, result)` creates the complete
pair before it returns a native `Table *`. `result` is an active, caller-owned
stack slot distinct from the rooted writer:

1. assert the compiler-guaranteed metatable, writer, capacity, and result-slot
   preconditions;
2. allocate the table and publish it in `result`;
3. call `luaH_resize(L, backing, capacity, 1)`;
4. initialize logical length to zero, without dereferencing `lenhint` when
   `asize == 0`;
5. allocate a zero-byte, two-uservalue Udata with `luaS_newudata`;
6. write its metatable, backing, and writer fields directly;
7. temporarily publish the proxy in `result`;
8. insert `0 -> proxy` in the already-sized hash;
9. apply the stock barriers and restore the backing to `result`; and
10. poll the collector only after the complete cycle is rooted.

`titan_const_array_new(L, const_metatable, capacity, result)` uses the same
internal constructor but requires the const canonical metatable and stores nil
in user value 2. A constructor checked under a const Array target calls this
helper directly and never creates a transient mutable proxy.

The empty case deliberately requests `luaH_resize(L, t, 0, 1)`. Its array part
has size zero, but its non-dummy one-node hash still owns key 0.
Bundled Lua 5.5 has no capacity-taking variant of `luaH_new`; this
`luaH_new`-then-`luaH_resize` sequence is the same internal construction shape
used by Lua's own table-creation paths, without involving the public stack API.

The caller keeps the mutable writer rooted. The one result slot first roots the
backing, then the proxy whose first user value already traces that backing, and
finally the completed backing/proxy cycle. This ordering is necessary because
`luaH_resize` can allocate before either edge exists and `luaH_setint` can force
an emergency full collection under Lua's `HARDMEMTESTS`. A C local `Table *`,
`Udata *`, or `TValue` is not a GC root. The helper never changes `L->top`.

Constructor lowering fills the positive array slots after the pair exists.
It then stores the highest non-nil produced position as the final length.
The position count can be larger than the length when a `{value}` constructor
contains trailing nils.

## Stock GC ownership and barriers

There is no custom Array GC kind, finalizer, owner map, patched mark routine,
or manual free path:

- the Table owns and frees its ordinary array block and one-node hash;
- the Udata owns its ordinary header and two user values;
- the strong cycle and any mutable writer edge are traversed by stock
  Table/Udata/CClosure marking;
- incremental and generational collectors handle unreachable cycles; and
- state close frees both objects through Lua's normal object switch.

Every edge uses the ordinary barrier for its actual owner:

| Store | Owner to barrier |
| --- | --- |
| proxy user value 1 → backing Table | proxy Udata |
| mutable proxy user value 2 → writer CClosure | proxy Udata |
| writer upvalue 0 → constructing `_mod` | writer CClosure |
| backing key 0 → proxy Udata | backing Table |
| backing positive slot → collectable element | backing Table |
| compiler slot → backing Table | the existing module/record/closure owner |

The hot Array-element store barriers `obj2gco(backing)`, never the proxy.
The mutable writer closure is first cached in a module user value with the module's
back barrier; `lua_pushcclosure` installs its `_mod` upvalue during
construction, and the proxy user-value API applies the corresponding Udata
barrier. Across a resize, generated code roots the backing, a collectable
right-hand side, open constructor/result values, and any proxy needed by a
boundary conversion. Lua can relocate its stack during allocation, so saved
stack offsets are restored and raw stack-derived pointers are recomputed
afterward.

## Authoritative `lenhint` and resizing

Lua 5.5 stores its table-length search hint in an unsigned word immediately
beside the array allocation. Titan uses that stock word as authoritative
Array state through `lenhint(t)`.

`titan_array_length` guards `asize == 0` before dereferencing the word.
`titan_array_set_length` asserts `length <= asize`. Generated `#array` reads
the guarded hint directly; it never calls `luaH_getn`.

This distinction matters because Lua treats `lenhint` as a mutable search
cache. `luaH_getn` may select any valid border in a holed ordinary table and
write that border back. Titan instead maintains the highest-present-positive
border after every write:

- a non-nil write above length raises length to the index;
- a write below or at length otherwise leaves it unchanged;
- an interior nil write leaves length unchanged;
- deleting at exactly length scans backward over empty slots; and
- nil beyond capacity is a no-op.

`luaH_resizearray` internally resets the hint to `newasize / 2`. Therefore
`titan_array_resize` saves the logical length, calls the stock resize, and
restores the saved value immediately. The stock resize also rebuilds the hash
and reinserts key 0 while preserving its logical one-node size.

Growth selects the smallest power of two strictly greater than the requested
logical index. `TITAN_ARRAY_MAX_CAPACITY` mirrors pinned Lua 5.5's private
`MAXASIZE` expression exactly:

```c
min(1u << (l_numbits(int) - 1),
    MAX_SIZET / (sizeof(Value) + 1))
```

Capacity is checked in `lua_Unsigned` before narrowing to `unsigned`.
Unsupported growth raises `array index too large` before a hash fallback or
integer truncation can occur. Later resizes never shrink an Array.

## Canonical proxy and module cache

`titan_array_metatables` creates or recovers the mutable/const registry pair
per Lua state. Both install closures for:

- `__index`, which accepts exactly an integral numeric key, returns nil below
  1, and reads only the positive array slot;
- `__len`, which reads the guarded authoritative length; and
- protected qualifier-specific `__name`/`__metatable` text.

Only the mutable metatable installs `__newindex`, which validates a positive
integral index, handles nil as deletion, and otherwise invokes the
receiver-carried writer before native growth/hole/length transitions. The
const metatable has no write path.

Creation is build-then-publish: the runtime fills both private metatables and
publishes one canonical pair table only after every allocating setup step
succeeds. The legacy named entries are projections repaired from that pair.
No callback can observe one canonical identity before the other is complete,
and a malformed pre-existing pair is rejected.

There is no `__pairs`. The read callbacks capture both canonical identities,
so nested boxing can recognize either qualifier without querying the registry
on each access. The mutable write callback captures its mutable identity.

Every generated module reserves two consecutive unconditional private
user-value slots for the mutable and const metatables. Slot allocation places
them after the
importer-reconstructed public prefix—exported variables and canonical exported
function closures—and before other private caches. Cold initialization stores
both metatables immediately after the module Udata is registry-anchored and
before imports, record setup, or `INITVARS`; module-variable initializers may
construct or box Arrays. Recovered modules already carry the slot.

For every distinct final element type of a mutable Array constructor emitted by
a module, the coder also allocates one private module slot and generates one
writer `CClosure`. The checker has already attached the element's canonical
`DynamicCoercionPlan`; the generated writer captures `_mod`, converts its one
incoming Lua value into the element's internal/boxed slot representation, and
returns the converted `TValue`. Writer closures initialize after imports,
record caches, and function-type tag publication, but **before `INITVARS`**,
so a module-variable initializer can construct an Array. Construction loads
the cached closure and passes it to `titan_array_new`.

There is no global writer registry, interning, or "first one wins" identity.
Two modules may generate distinct but extensionally equivalent writers for
`{integer}`. Projection through `value`, alternate gradual views, imports,
returns, and nested boxing preserve the existing qualified canonical proxy and,
for a mutable Array, its writer; no operation compares or replaces writer
identity.

The metatable pair cache is used by proxy construction and boxing/unboxing checks.
A normal typed Array read, write, or length operation touches only the backing
Table and does not load the writer. In particular, a nested Array check still
uses direct comparison with one of the two canonical metatables rather than
chasing a per-type marker.

### Structural validation

Boundary helpers validate both directions:

- `titan_array_try_proxy(backing, metatable)` nonthrowingly checks key 0,
  full-Udata shape, zero payload, exactly two user values, canonical metatable,
  reverse link, and `length <= asize`;
- `titan_array_try_proxy_either(backing, mutable_metatable, const_metatable)`
  recognizes either canonical tag for nested/raw-backing recovery;
- `titan_array_require_proxy` raises on a failed required conversion;
- `titan_array_try_backing(value, metatable)` checks the proxy shape, Table
  user value, absent Table metatable, reverse key-0 link, and guarded length;
  and
- `titan_array_require_backing` raises for a non-Array proxy.

The nonthrowing backing probe is essential when a dynamic value happens to be
an ordinary Map Table: "not an Array backing" is a normal negative result, not
corruption.

Ordinary validation deliberately does not inspect user value 2. Only mutable
`__newindex` loads and invokes it for a non-nil Lua write; the const constructor
and freeze helper maintain the nil invariant. Supported code never mutates
either ownership link, qualifier, or writer. Debug-library or
C-level forgery/corruption is programmer-responsible and outside the
untrusted-code contract; the helpers do not add writer-identity checks or
attempt to repair arbitrary damaged Lua objects.

## Internal and boxed representations

The compiler distinguishes storage domains and qualifier by semantic Titan
type:

- `I(Array(T, isconst))` is compiler-owned typed/internal storage: a backing `Table *` or
  a Table-tagged `TValue`;
- `B(Array(T, isconst))` is Lua-canonical storage: the exact qualified proxy `Udata *` or a
  Udata-tagged `TValue`.

| Context | Array representation |
| --- | --- |
| native local, exact argument/result | backing `Table *` |
| typed module/record/capture/spill slot | backing Table TValue |
| typed union payload slot | backing Table TValue |
| compiler-written nested Array element | backing Table TValue |
| Lua stack or generic callable boundary | proxy Udata TValue |
| `value` containing an Array | proxy Udata TValue |
| raw-visible Map key/value | proxy Udata TValue |
| exact variadic/flexible element buffer | backing `Table **` |
| boxed `Option(Array)` | nil or proxy TValue |
| internal `Option(Array)` | nil or backing Table TValue |

Consequences:

- `ctype(Type.Array)` remains `Table *`;
- exact signatures and out-parameters remain `Table *`;
- `TitanVargArrayOrMap` remains `Table **`;
- typed slots continue to use `hvalue`/`sethvalue`;
- `value` never carries a raw backing Table;
- Map storage boxes Array keys and values; and
- record/module accessors box on get and unbox on set while their internal
  slots stay raw; and
- union construction/extraction likewise keeps the backing Table in `uv[1]`
  rather than passing through the Lua proxy.

The shared `Table *` carrier never determines mutability. Boxing, unboxing,
strict guards, dynamic conversion, generic descriptors, and Interface field
adjustments select the mutable or const tag from `Type.Array.isconst`.

Array and Map share the C type `Table *`, while `Option(Array)`, `value`, and
Function can all use `TValue`. Representation selection therefore cannot
dispatch on C type alone. The coder uses semantically typed boxing, copying,
and mixed-read paths rather than one representation-blind "wrapped value"
helper.

### Nested Array rule

A Titan write to `Array<Array<T>>` stores the inner backing Table directly and
barriers outer backing → inner backing. Lua `__newindex` passes the incoming
proxy through the outer Array's writer; the writer validates/unboxes it and
returns the internal backing representation before the shared callback
commits the store.

A typed nested read first accepts either structural backing tag, then recovers
the exact proxy required by the requested nested qualifier. Its physical fast
paths are:

- a structurally validated raw backing fast path; or
- a canonical proxy that is validated and unboxed.

An `Array<value>` read is different: an Array proxy inside the dynamic value
must remain boxed. Ordinary Map Tables—including one with an unrelated key-0
entry—pass through the nonthrowing probe unchanged.

## Checker elaboration

The ABI-0.26 schema is `Type.Array(elem, isconst)`, where `isconst` is a
required exact boolean. `Type.Map(keys, values)` remains unqualified. Array
equality, consistency, substitution, rewriting, erasure, guard/dynamic plans,
and serialization all retain the qualifier. Indexed reads remain optional;
only mutable Array indices are lvalues.

Ordinary assignment and gradual consistency never change the qualifier.
`types.written_cast` alone admits mutable `Array(S, false)` to const
`Array(T, true)` when the elements are equal or gradually consistent. The
default `array_freeze` mode is a shallow copy; const-to-mutable is absent. A
static matching `is` returns the admitted result without lowering the
conversion, while a source `value` checks the exact qualified runtime tag.

After typechecking, `checker/linear.lua` may change a copy plan to in-place
freeze for one un-rebound local initialized from a fresh mutable constructor.
Before its terminal same-block cast, loops and structured builder statements
may use its length and indexed reads/writes; unrelated calls and closures that
do not reference the Array are harmless. Passing, storing, returning, aliasing,
rebinding, or actually capturing the Array, hiding the consuming cast inside
control flow, or any later source/alias use keeps the copy. The coder consumes
this annotation and never recomputes escape or liveness facts.

### Length

The checker accepts:

- String and the existing countable C types;
- Array; and
- Map only when its fully resolved key type is exactly `Type.Integer`.

It does not admit `value`, Float, a foreign C integer, or another compatible
key type as an integer Map. The distinction determines whether code generation
uses the explicit Array hint or metamethod-aware ordinary-table length for a
Map. A metatable does not make any rejected Map key type admissible.

### Positional constructors

`Ast.ExpInitList` classifies fields as empty, all-positional, all-computed,
named, or invalid mixed forms. For an Array—or for a context whose exact type
is `Map(Integer, V)`—the checker:

1. derives the positional element/value context;
2. calls `adjust_explist` once;
3. checks/coerces each fixed scalar and open tail once;
4. preserves left-to-right evaluation, discard, and error order;
5. records the result as `_positional_adjustment`; and
6. for an Array, freezes the final element type, qualifier, and
   `DynamicCoercionPlan`; mutable construction uses it as the future Lua writer
   policy, while const construction does not install a writer.

This shared annotation is representation-neutral. Array code generation
creates the backing/proxy protocol; positional integer-Map generation creates
an ordinary Table.

No-context positional construction still defaults to Array. Empty `{}` can
take any context-provided Map type. Nonempty positional construction requires
Array or exact integer Map context. Computed keys stay scalar Map entries,
named fields stay record syntax, and mixed shapes produce deliberate
diagnostics rather than entering the wrong checker arm.

The adjusted final producer can be fixed multiple return, flexible return,
contextual `value` call, or input `...`. Its element adjustment is retained on
the open producer and consumed by code generation; unequal element types no
longer cause the coder to synthesize a scalar cast. Each actual result consumes
one position even when a `value`-consistent nil becomes an absent table slot.

## Generated operations

### Array reads

Array bracket lowering:

1. evaluates the backing and index once;
2. branches to nil when the signed index is below 1;
3. converts to an unsigned zero-based slot only afterward;
4. reads with `arr2obj` (the direct `getArrTag`/`getArrVal` array-part
   macro) only when `slot < asize`; and
5. produces nil otherwise.

There is no hash lookup, allocation, registry lookup, metatable dispatch, or
length scan.

The static result is `Option(T)`. Its present arm uses the strict
`GuardPlan(T)`: integer, float, and boolean require their exact tags; C
integer/float, C `TValue`, owned C userdata, nominal, and nested container
categories have explicit complete arms. Recursive Option handling preserves
nil and applies the same strict rule to a present value. It never substitutes
the broader numeric/truthiness `DynamicCoercionPlan`.

Storage-domain normalization remains explicit: `Option(Array)` accepts nil, a
validated raw backing, or a validated proxy; `Option(value)` boxes an internal
Array but passes an ordinary Map through; `Option(Map)` accepts an ordinary
Table and rejects an Array proxy. The writer user value is neither read nor
compared.

### Array writes

The checker rejects an indexed lvalue whose resolved Array type has
`isconst == true`, before assignment bookkeeping. Generated mutation code is
therefore reachable only for a mutable Array; the coder asserts this invariant.

The generic `_materialize_assignment_lvalue` path handles both single and
multiple assignments. For an Array-element target it delegates to
`_materialize_array_lvalue`, which evaluates the Array and index exactly once
in that order and retains the backing in a scanned slot. `_codeadjustedfixed`
then evaluates and roots the right-hand value. Only afterward does
`codeassignment` reject an index below 1, before unsigned conversion, and
mutate the backing.

For multiple assignment, the pass evaluates and freezes every effectful target
operand in lexical left-hand order — including record receivers, Map
containers and keys, Array backings and indices, and C field/index operands —
before evaluating any right-hand expression. The descriptors keep GC owners
and keys rooted. Once every right-hand value is materialized,
`codeassignment` performs target validation and mutation from left to right.
Thus an earlier Map, record, Array, or C store can commit before a later
invalid Array index raises; no later store runs. See [Code generator:
constructs](codegen-constructs.md#locals-and-assignment).

An Array mutation then:

- writes nil in capacity or performs the tail backscan;
- treats nil beyond capacity as a no-op; or
- computes growth, preserves length across resize, refreshes relocated stack
  pointers, and writes the non-nil value.

The store uses `obj2arr` and barriers the backing Table for collectable values.
No user entry uses `luaH_setint`. The common in-capacity write has no proxy,
uservalue, or metatable load.

This is a Titan write through the current static view. It never invokes the
construction writer and therefore does not establish a heap invariant about
all slots. A write through `{value}` may make a later `{integer}` read fail its
strict guard; that checked failure is the gradual-view contract.

Lua writes follow the separate shared callback. The callback validates the
index first. Nil delegates directly to deletion (including the
allocation-free beyond-capacity no-op) and bypasses element conversion. For a
non-nil value it preflights oversized growth, calls proxy user value 2 with the
incoming value, and mutates the backing only after the writer returns the
converted slot. A conversion error therefore leaves capacity, length, and
contents unchanged. The resulting rooted value survives any resize before
`titan_array_set_stack` commits it and applies the backing barrier.

### Constructors

The positional materializer preserves every fixed/open producer and roots its
values. Array lowering consumes the checker qualifier and element annotation,
computes the actual produced count, and validates exact capacity. A mutable
target inventories/recovers its module-cached writer and calls
`titan_array_new`; a const target calls `titan_const_array_new` with the const
metatable and no writer. Both copy positions into the array part, apply element
barriers, and record the highest non-nil position.

Positional integer-Map lowering reuses the expression-run adjustment but
allocates an ordinary Table, preallocates its array part to the produced
count, and assigns keys `1..N`. It has no explicit highest-present length.
Both keyed and positional Map stores box an Array key/value before placing it
in raw-visible Map storage.

### Mutable-to-const lowering

A copy-mode `array_freeze` calls `titan_array_shallow_copy`. The helper
asserts the source's mutable canonical proxy, relies on the caller's distinct
source root across destination allocation, and publishes the destination into
the caller-provided result slot. Its array part is preallocated to the source's
physical `asize` exactly. It copies only present slots through the source's
logical length, barriers every collectable destination value, and then restores
that logical length. Spare physical capacity remains empty; holes and
trailing-length semantics are preserved.

A checker-proven freeze-mode plan calls `titan_array_freeze`. It validates the
mutable proxy with debug assertions, installs the const canonical metatable by
writing the userdata directly and applying Lua's internal object barrier and
finalizer bookkeeping, clears user value 2 to nil, and returns the unchanged
`Table *`. Neither helper performs an element conversion or changes `L->top`.
The in-place path is sound only because the checker proved that no mutable
reference remains observable.

### Length

Array lowering uses `titan_array_length`/the guarded hint and remains entirely
separate from Map metamethod dispatch. Integer-Map lowering first uses cached
`TM_LEN` absence to keep `luaH_getn(L, map)` as its likely raw path and
therefore retains Lua-border semantics when `__len` is absent. When it may be
present, lowering boxes the Map and calls `luaV_objlen` with a reserved stack
result, restores `_base`, and requires the result's exact integer tag before
unboxing. Other Map key types fail in the checker. The complete generated shape
is in [Code generator: constructs](codegen-constructs.md#length-code_map_length).

## Exact and generic call paths

An Array-typed exact/native edge passes the backing pointer directly:

```text
argument/result/local/out: Table *
variadic/flexible element buffer: Table **
descriptor: TitanVargArrayOrMap
```

Lua entries, contextual calls through `value`, branded exact-tag-mismatch
function calls, raw Map storage, and exported accessors are boxed boundaries.
Outgoing Arrays become proxies selected by `Type.Array.isconst`; incoming
Array positions require and unwrap the exact target-qualified canonical proxy.
Options apply the selected strict or dynamic policy recursively.

Function values still dispatch through exact native, branded mismatch, and
non-Titan routes. A statically known non-exact callable edge may first create a
fresh target-tagged wrapper: its exact native adapter applies strict Array
component boxing/unboxing without replacing the carried qualifier or mutable
writer. An ineligible
branded value uses the strict trailing stack entry; a non-Titan callable uses
Lua's ordinary path and dynamic result conversion. A wrapper's genuine-Lua
`CClosure.f` remains the source entry. None of these routes changes an Array's
qualifier or compares/replaces its mutable writer.

Dispatch is based on semantic Titan type, not descriptor family:
`TitanVargArrayOrMap` cannot reveal whether a `Table **` element is an Array
that needs boxing or a Map that must stay a Table, and a `TValue *` cannot
distinguish `Option(Array)` from `value`.

An exact call can still box because its *declared* type is `value` or because
it stores an Array in a Map. That is a boxed storage boundary, not an
Array-typed call edge.

## Standalone arguments

Standalone `main(args: {string}): integer` uses the same ordinary Array
constructor and supplies a fixed generated `{string}` writer closure. The
driver creates it as a full C closure with one private dummy upvalue and keeps
it rooted on the Lua stack while `titan_array_new` writes the backing into a
separate traced result slot; no global per-type writer registry is involved.
Generated startup stores C `argv[1..argc-1]` at Titan positions `1..argc-1`,
sets length to `argc - 1`, and never writes user data at key 0.

Both direct startup and `titan.uv.bootstrap` push the canonical proxy into the
module's Lua entry wrapper. The wrapper validates/unboxes it before calling
the exact native `main` with `Table *`. Consequently the executable name is
not in the Array, `args[0]` is nil, and `#args == argc - 1`.

## ABI 0.17, 0.20, 0.21, 0.22, 0.23, 0.24, 0.25, and 0.26 boundaries

ABI 0.17 is a semantic and boundary-protocol break even though serialized
`Array(...)` text, native pointer width, exact `Table *` signatures, and
`Table **` descriptors are unchanged.

ABI-0.16 generated code could:

- let `luaH_getn` treat `lenhint` as a mutable border cache;
- resize without restoring explicit length;
- read or write key 0;
- preserve negative entries;
- store high positive indices in the hash; and
- accept or expose raw Tables at Lua/`value` boundaries.

Mixing those operations with ABI-0.17 Arrays can destroy the proxy link or
length/storage invariants. The ABI gate protects that representation contract;
it is not a `Table *` → `Udata *` migration.

ABI-0.17 providers lived under `lib/titan/0.17`, used
`TITAN_PATH_0_17`, and rejected 0.16 dependencies through the existing
provider ABI protocol. ABI 0.18 preserved the same Array contract while
advancing the standard-library archive/runtime native-symbol boundary.
ABI 0.19 still preserved that one-user-value proxy and had no strict callable
trailer. ABI 0.20 changed the proxy shape to exactly two user values, added the
construction writer, added the three-entry function closure protocol, and
carries the coordinated Interface wrapper/metadata contract. Interface
satisfaction remains an outer scalar coercion: it does not make `{R}` and
`{I}` consistent, and typed Array reads only accept an already wrapped exact
Interface element.
ABI 0.21 retained the ABI-0.20 Array and function layouts while advancing the
matched Lua internal-header/runtime contract to 5.5.1. ABIs 0.22 and 0.23
retained those Array, function, and Lua layouts, and ABIs 0.24 and 0.25 retained
them again. ABI 0.26 requires the boolean-qualified Array descriptor, adds the
distinct const tag/metatable and two-slot module cache, and exports const
construction plus shallow-copy/in-place-freeze operations while retaining the
dense backing and exact `Table *` native contract. Current
providers live under `lib/titan/0.26` and use `TITAN_PATH_0_26`; an ABI-0.26
compiler/runtime rejects ABI-0.25 DSOs and
archives before any Array or function value can cross the provider boundary.
Separately installed 0.17 through 0.25 trees remain versioned predecessors and
are not migrated, cleaned up, or treated as compatible.

## Failure and performance boundaries

- Positive read and in-capacity write are O(1) direct slot operations.
- `#array` is O(1).
- Growth is amortized and preserves key 0 and length.
- Tail deletion is O(1) without preceding holes and O(n) when it must scan
  backward over them.
- Boxing, unboxing, and structural validation are O(1) boundary operations.
- Every Array pays for one Udata, two user values, and one live hash entry in
  addition to its Table array storage. A mutable Array also references a
  module-cached writer closure; a const Array's second user value is nil.
  Closures are reused per constructed element type within a module.
- Shallow copy is O(source physical capacity allocation plus logical-range
  copying); a proven linear freeze is O(1).
- Oversized construction/growth fails before narrowing or Table overflow.
- The backing/length contract introduced in ABI 0.17 and retained through ABI
  0.26 has no shrinking resize.

### Raw and stock table-library boundary

A Titan Array is table-like but not a Lua Table. Lua's raw functions
`rawget`, `rawset`, and base-library `rawlen` reject the proxy as a non-Table.
Stock Lua 5.5's `table` library is intentionally different: its `checktab`
path accepts a non-table whose raw metatable provides the required `__index`,
`__index`, `__newindex`, and `__len` fields. Applicable `table.*` operations
therefore run through mutable proxy callbacks. A const proxy has only
`__index`/`__len`, so read-only operations can work while a mutating operation
fails. This is stock behavior, not a Titan wrapper or Lua patch.

The debug library and C API can reveal or corrupt the private cycle, writer
user value, and `lenhint`. Preserving Titan invariants is the programmer's
responsibility when using those privileged APIs; the debug library is not
available to untrusted code. Titan does not add writer validation on the hot
read path, a patched Lua state marker, anti-debug protocol, special table
flag, custom collector hook, or recovery path.

## Focused evidence

`spec/dense_array_runtime_spec.lua` compiles the runtime against pinned stock
Lua internals and verifies:

- exact capacities, growth boundaries, key-0 survival, and hint restoration;
- positive-only reads/writes, holes, tail backscan, distinct mutable/const
  tags, and exactly two proxy user values in backing/writer-or-nil order;
- writer dispatch, nil bypass, conversion-before-mutation, and writer/_mod
  survival under full and generational GC;
- proxy callbacks, nested backing boxing, and ordinary Map pass-through;
- structural validation and atomic per-state metatable-pair identity;
- exact-capacity shallow copy, holes/length/barriers, and in-place
  retag/writer-clear freeze;
- proxy-only, backing-only, and unreachable-cycle behavior in incremental and
  generational modes;
- old backing → young collectable barriers and stable collection envelope;
- ordinary state close; and
- a separately compiled full-Lua `HARDMEMTESTS`/API-check construction proof.

Checker and generated-C behavior live in
`spec/checker/dense_arrays_spec.lua` and `spec/coder/dense_arrays_spec.lua`.
Those suites cover module-local writer caching, strict Titan reads versus
coercive mutable Lua writes, const write rejection, qualifier-exact dynamic
views, alternate construction/static views, open constructors, C-valued
elements, `table.*` behavior, and construction from more than one module. The
const-value checker/coder suites add written casts and linear builder elision.
