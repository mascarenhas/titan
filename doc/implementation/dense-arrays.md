# Dense Arrays

Titan ABI 0.17 gives `Type.Array(T)` a deterministic, positive-only dense
storage protocol while preserving its native C representation as `Table *`.
The compiler distinguishes the native backing object from the canonical
Lua-visible proxy, maintains the logical length explicitly, and never stores a
user Array entry in the table hash part.

This chapter describes the runtime protocol, checker elaboration, generated-C
lowering, GC rules, and ABI boundary. Language-visible behavior is specified
in [Arrays and maps](../language/arrays-maps.md).

## Representation contract

An Array consists of two ordinary stock-Lua objects:

1. a normal `Table` used as the exact/native backing; and
2. a zero-payload full `Udata` used as the canonical boxed proxy.

They form a strong cycle:

```text
backing Table hash key 0 ───────────────► proxy Udata
          ▲                                  │
          └──────────── user value 1 ◄───────┘
```

The proxy has exactly one user value and the shared per-state
`"Titan array metatable"`. The backing table has no metatable. Integer key 0
is private and is the table's only live hash entry; every user position is a
positive index in the array part.

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
- the backing has no metatable.

Logical length is therefore the highest present positive index, not an element
count and not whichever valid border Lua's table-length search happens to
choose.

## Runtime construction

`titan_array_new(L, metatable, capacity)` creates the complete pair before it
returns a native `Table *`:

1. validate the requested capacity against `TITAN_ARRAY_MAX_CAPACITY`;
2. allocate the table and root it in a scanned Lua stack slot;
3. allocate a zero-byte, one-uservalue Udata and independently root it;
4. set the proxy metatable with the ordinary Lua API;
5. call `luaH_resize(L, backing, capacity, 1)`;
6. initialize logical length to zero, without dereferencing `lenhint` when
   `asize == 0`;
7. install backing Table in proxy user value 1;
8. insert `0 -> proxy` in the already-sized hash; and
9. apply the stock barriers and publish only after both links exist.

The empty case deliberately requests `luaH_resize(L, t, 0, 1)`. Its array part
has size zero, but its non-dummy one-node hash still owns key 0.

Both objects stay in independent scanned roots across every allocation.
This is necessary even though the links eventually form a cycle:
`luaH_resize` can allocate before either edge exists, and `luaH_setint` can
force an emergency full collection under Lua's `HARDMEMTESTS` before the
caller's later barrier. A C local `Table *`, `Udata *`, or `TValue` is not a
GC root.

Constructor lowering fills the positive array slots after the pair exists.
It then stores the highest non-nil produced position as the final length.
The position count can be larger than the length when a `{value}` constructor
contains trailing nils.

## Stock GC ownership and barriers

There is no custom Array GC kind, finalizer, owner map, patched mark routine,
or manual free path:

- the Table owns and frees its ordinary array block and one-node hash;
- the Udata owns its ordinary header and one user value;
- the strong cycle is traversed by stock Table/Udata marking;
- incremental and generational collectors handle unreachable cycles; and
- state close frees both objects through Lua's normal object switch.

Every edge uses the ordinary barrier for its actual owner:

| Store | Owner to barrier |
| --- | --- |
| proxy user value 1 → backing Table | proxy Udata |
| backing key 0 → proxy Udata | backing Table |
| backing positive slot → collectable element | backing Table |
| compiler slot → backing Table | the existing module/record/closure owner |

The hot Array-element store barriers `obj2gco(backing)`, never the proxy.
Across a resize, generated code roots the backing, a collectable right-hand
side, open constructor/result values, and any proxy needed by a boundary
conversion. Lua can relocate its stack during allocation, so saved stack
offsets are restored and raw stack-derived pointers are recomputed afterward.

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

`titan_array_metatable` creates or recovers one shared registry metatable per
Lua state. It installs closures for:

- `__index`, which accepts exactly an integral numeric key, returns nil below
  1, and reads only the positive array slot;
- `__newindex`, which applies the same index classification and native
  growth/hole/length transitions;
- `__len`, which reads the guarded authoritative length; and
- protected `__name`/`__metatable` text `"Titan array metatable"`.

There is no `__pairs`. The callbacks capture the canonical metatable, so a
nested-backing probe does not query the registry on each access.

Every generated ABI-0.17 module reserves one unconditional private user-value
slot for this metatable. Slot allocation places it after the
importer-reconstructed public prefix—exported variables and canonical exported
function closures—and before other private caches. Cold initialization stores
the metatable immediately after the module Udata is registry-anchored and
before imports, record setup, or `INITVARS`; module-variable initializers may
construct or box Arrays. Recovered modules already carry the slot.

The cache is used by proxy construction and boxing/unboxing checks. A normal
typed Array read, write, or length operation touches only the backing Table and
does not load the cache or query the registry.

### Structural validation

Boundary helpers validate both directions:

- `titan_array_try_proxy(backing, metatable)` nonthrowingly checks key 0,
  full-Udata shape, zero payload, exactly one user value, canonical metatable,
  reverse link, and `length <= asize`;
- `titan_array_require_proxy` raises on a failed required conversion;
- `titan_array_try_backing(value, metatable)` checks the proxy shape, Table
  user value, absent Table metatable, reverse key-0 link, and guarded length;
  and
- `titan_array_require_backing` raises for a non-Array proxy.

The nonthrowing backing probe is essential when a dynamic value happens to be
an ordinary Map Table: "not an Array backing" is a normal negative result, not
corruption.

Supported code never mutates either ownership link. Debug-library or C-level
forgery/corruption is outside the contract; the helpers do not attempt to
repair arbitrary damaged Lua objects.

## Internal and boxed representations

The compiler distinguishes storage domains by semantic Titan type:

- `I(Array)` is compiler-owned typed/internal storage: a backing `Table *` or
  a Table-tagged `TValue`;
- `B(Array)` is Lua-canonical storage: the proxy `Udata *` or a
  Udata-tagged `TValue`.

| Context | Array representation |
| --- | --- |
| native local, exact argument/result | backing `Table *` |
| typed module/record/capture/spill slot | backing Table TValue |
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
  slots stay raw.

Array and Map share the C type `Table *`, while `Option(Array)`, `value`, and
Function can all use `TValue`. Representation selection therefore cannot
dispatch on C type alone. The coder uses semantically typed boxing, copying,
and mixed-read paths rather than one representation-blind "wrapped value"
helper.

### Nested Array rule

A Titan write to `Array<Array<T>>` stores the inner backing Table directly and
barriers outer backing → inner backing. Lua `__newindex` instead stores its
incoming Lua value verbatim, so a nested Array written from Lua is already a
proxy.

A typed nested read accepts either:

- a structurally validated raw backing fast path; or
- a canonical proxy that is validated and unboxed.

An `Array<value>` read is different: an Array proxy inside the dynamic value
must remain boxed. Ordinary Map Tables—including one with an unrelated key-0
entry—pass through the nonthrowing probe unchanged.

## Checker elaboration

The type schema is unchanged: `Type.Array(elem)` and `Type.Map(keys, values)`
remain distinct structural constructors, indexed reads remain optional, and
indexed lvalues remain nil-capable.

### Length

The checker accepts:

- String and the existing countable C types;
- Array; and
- Map only when its fully resolved key type is exactly `Type.Integer`.

It does not admit `value`, Float, a foreign C integer, or another compatible
key type as an integer Map. The distinction determines whether code generation
uses the explicit Array hint or Lua's ordinary Map-border search.

### Positional constructors

`Ast.ExpInitList` classifies fields as empty, all-positional, all-computed,
named, or invalid mixed forms. For an Array—or for a context whose exact type
is `Map(Integer, V)`—the checker:

1. derives the positional element/value context;
2. calls `adjust_explist` once;
3. checks/coerces each fixed scalar and open tail once;
4. preserves left-to-right evaluation, discard, and error order; and
5. records the result as `_positional_adjustment`.

This shared annotation is representation-neutral. Array code generation
creates the backing/proxy protocol; positional integer-Map generation creates
an ordinary Table.

No-context positional construction still defaults to Array. Empty `{}` can
take any context-provided Map type. Nonempty positional construction requires
Array or exact integer Map context. Computed keys stay scalar Map entries,
named fields stay record syntax, and mixed shapes produce deliberate
diagnostics rather than entering the wrong checker arm.

The adjusted final producer can be fixed multiple return, flexible return,
contextual `value` call, or input `...`. Each actual result consumes one
position even when a value-compatible nil becomes an absent table slot.

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

The static result is `Option(T)`. Recursive option conversion understands the
storage domain: `Option(Array)` accepts nil, a validated raw backing, or a
validated proxy; `Option(value)` boxes an internal Array but passes an
ordinary Map through; `Option(Map)` accepts an ordinary Table and rejects an
Array proxy.

### Array writes

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

### Constructors

The positional materializer preserves every fixed/open producer and roots its
values. Array lowering computes the actual produced count, validates the exact
capacity, constructs the complete backing/proxy pair, copies positions into
the array part, applies element barriers, and records the highest non-nil
position.

Positional integer-Map lowering reuses the expression-run adjustment but
allocates an ordinary Table, preallocates its array part to the produced
count, and assigns keys `1..N`. It has no explicit highest-present length.
Both keyed and positional Map stores box an Array key/value before placing it
in raw-visible Map storage.

### Length

Array lowering uses `titan_array_length`/the guarded hint. Integer-Map lowering
uses `luaH_getn(L, map)` and therefore retains Lua-border semantics. Other Map
key types fail in the checker.

## Exact and generic call paths

An Array-typed exact/native edge passes the backing pointer directly:

```text
argument/result/local/out: Table *
variadic/flexible element buffer: Table **
descriptor: TitanVargArrayOrMap
```

Lua entries, contextual calls through `value`, compatible function values that
take the generic path, raw Map storage, and exported accessors are boxed
boundaries. Outgoing Arrays become proxies; incoming Array positions require
and unwrap canonical proxies. Options apply the same conversion recursively.

Dispatch is based on semantic Titan type, not descriptor family:
`TitanVargArrayOrMap` cannot reveal whether a `Table **` element is an Array
that needs boxing or a Map that must stay a Table, and a `TValue *` cannot
distinguish `Option(Array)` from `value`.

An exact call can still box because its *declared* type is `value` or because
it stores an Array in a Map. That is a boxed storage boundary, not an
Array-typed call edge.

## Standalone arguments

Standalone `main(args: {string}): integer` uses the same ordinary Array
constructor. Generated startup stores C `argv[1..argc-1]` at Titan positions
`1..argc-1`, sets length to `argc - 1`, and never writes user data at key 0.

Both direct startup and `titan.uv.bootstrap` push the canonical proxy into the
module's Lua entry wrapper. The wrapper validates/unboxes it before calling
the exact native `main` with `Table *`. Consequently the executable name is
not in the Array, `args[0]` is nil, and `#args == argc - 1`.

## ABI 0.17 boundary

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

ABI-0.17 providers live under `lib/titan/0.17`, use
`TITAN_PATH_0_17`, and reject 0.16 dependencies through the existing provider
ABI protocol. A separately installed 0.16 tree is preserved for migration and
rollback rather than treated as compatible.

## Failure and performance boundaries

- Positive read and in-capacity write are O(1) direct slot operations.
- `#array` is O(1).
- Growth is amortized and preserves key 0 and length.
- Tail deletion is O(1) without preceding holes and O(n) when it must scan
  backward over them.
- Boxing, unboxing, and structural validation are O(1) boundary operations.
- Every Array pays for one Udata, one user value, and one live hash entry in
  addition to its Table array storage.
- Oversized construction/growth fails before narrowing or Table overflow.
- There is no shrinking resize in ABI 0.17.

### Raw and stock table-library boundary

A Titan Array is table-like but not a Lua Table. Lua's raw functions
`rawget`, `rawset`, and base-library `rawlen` reject the proxy as a non-Table.
Stock Lua 5.5's `table` library is intentionally different: its `checktab`
path accepts a non-table whose raw metatable provides the required `__index`,
`__newindex`, and `__len` fields. Applicable `table.*` operations therefore
run through the Array proxy callbacks. This is stock behavior, not a Titan
wrapper or Lua patch.

The debug library and C API can reveal or corrupt the private cycle and
`lenhint`. Such use is undefined behavior. Titan does not add a patched Lua
state marker, anti-debug protocol, special table flag, custom collector hook,
or recovery path.

## Focused evidence

`spec/dense_array_runtime_spec.lua` compiles the runtime against pinned stock
Lua internals and verifies:

- exact capacities, growth boundaries, key-0 survival, and hint restoration;
- positive-only reads/writes, holes, and tail backscan;
- proxy callbacks, nested backing boxing, and ordinary Map pass-through;
- structural validation and per-state metatable identity;
- proxy-only, backing-only, and unreachable-cycle behavior in incremental and
  generational modes;
- old backing → young collectable barriers and stable collection envelope;
- ordinary state close; and
- a separately compiled full-Lua `HARDMEMTESTS`/API-check construction proof.

Checker and generated-C behavior live in
`spec/checker/dense_arrays_spec.lua` and `spec/coder/dense_arrays_spec.lua`.
