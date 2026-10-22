# Dense Arrays

`Type.Array(T, isconst)` has a deterministic, positive-only dense backing whose
native C representation is `Table *` for both the mutable and the const form.
Lua sees a zero-payload proxy userdata. A mutable proxy carries a
construction-selected Lua writer closure that converts genuine Lua writes before
mutation; a const proxy has no writer and no `__newindex`. Typed Titan reads are
strict.

This chapter is the canonical home for the Array runtime protocol, checker
elaboration, generated-C lowering, and GC rules. Language-visible behavior is
specified in [Arrays and maps](../language/arrays-maps.md). The runtime lives in
`titan-runtime/titan.c` and `titan-runtime/titan.h` (`titan_array_*`).

## Representation contract

An Array consists of two ordinary stock-Lua objects:

1. a normal `Table` used as the exact/native backing; and
2. a zero-payload full `Udata` used as the canonical boxed proxy.

The backing and proxy form a strong cycle. The proxy's second user value carries
the writer policy only for a mutable Array:

```text
backing Table array slot 0 ──────────────► proxy Udata
          ▲                                  │
          └──────────── user value 1 ◄───────┤
                                             └── user value 2 ──► writer CClosure ──► _mod
                                                              or nil for const
```

The proxy has exactly two user values and one of two canonical per-state
metatables. User value 1 (C index `uv[0]`) is the backing. Mutable user value 2
(`uv[1]`) is the module-local writer closure selected by the Array's final
construction element type; const user value 2 is nil. The metatable, not the
writer, is the exact mutable/const tag. Both canonical metatables are branded
under the lightuserdata key `TITAN_BRAND` with `TITAN_ARRAY` (1) or
`TITAN_CONST_ARRAY` (2) (`titan_array_initialize_metatable`). The writer is behavior for
genuine Lua writes, not proof of current contents. The backing table has no
metatable. Array slot 0 is private and holds the proxy; user element position
`k` (`1..N`) is array slot `k`.

For backing table `t`:

```c
capacity(t) = t->asize - 1; /* slots 1..asize-1 for elements, slot 0 for proxy */
length(t)   = *lenhint(t);
```

The maintained invariants are:

- `0 <= length <= capacity`;
- physical `asize` is `capacity + 1`, so `asize >= 1` and `lenhint(t)` is never
  NULL;
- array slot 0 holds the canonical proxy Udata;
- every slot in `(length, capacity]` is empty;
- when `length > 0`, slot `length` is non-nil;
- lower positive slots may be holes;
- the hash part is empty (`luaH_resize(..., 0)` leaves the shared dummy node);
- proxy user value 1 points to the same backing;
- proxy user value 2 is the constructing module's writer closure for a mutable
  Array and nil for a const Array; and
- the backing has no metatable.

Logical length is therefore the highest present positive index, not an element
count and not whichever valid border Lua's table-length search happens to
choose.

## Runtime construction

`titan_array_new(L, metatable, capacity, writer, result)` and
`titan_const_array_new(L, const_metatable, capacity, result)` are inline
wrappers over `titan_array_new_impl` (`titan-runtime/titan.c`). It creates the
complete pair before returning the native `Table *`. `result` is an active,
caller-owned stack slot distinct from the rooted writer. The helper:

1. asserts the compiler-guaranteed metatable, writer, capacity, and result-slot
   preconditions (a mutable writer must be a `CClosure`; a const call passes
   `NULL`);
2. allocates the table with `luaH_new` and publishes it in `result`;
3. calls `luaH_resize(L, backing, capacity + 1, 0)` and sets logical length 0;
4. allocates a zero-byte, two-uservalue Udata with `luaS_newudata`;
5. stores its metatable, backing, and writer fields directly, with
   `luaC_objbarrier`, `luaC_checkfinalizer`, and `luaC_barrierback` on the
   proxy;
6. stores the proxy in array slot 0 with `obj2arr` and barriers the backing;
   and
7. calls `luaC_checkGC` only after the complete cycle is reachable from
   `result`.

The proxy is never stored in `result`; it is reachable only through the
backing. A constructor checked under a const Array target calls the const
wrapper directly and never creates a transient mutable proxy. Bundled Lua 5.5
has no capacity-taking `luaH_new`; `luaH_new` then `luaH_resize` is the shape
Lua's own table constructors use, without the public stack API.

The helper never changes `L->top`, but its final `luaC_checkGC` can run a
collection step that shrinks the Lua stack. Generated callers therefore
restore `_base` from `_base_off` immediately after the call (see the
`initarray` templates in `titan-compiler/coder/expressions.lua`).

Constructor lowering fills the positive slots after the pair exists, then
stores the highest non-nil produced position as the final length. The position
count can exceed the length when a `{value}` constructor contains trailing
nils.

## Stock GC ownership and barriers

There is no custom Array GC kind, finalizer, owner map, patched mark routine,
or manual free path:

- the Table owns and frees its ordinary array block;
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
| proxy metatable | proxy Udata (`luaC_objbarrier`) |
| writer upvalue 1 → constructing `_mod` | writer CClosure (`lua_pushcclosure`) |
| module user value → writer CClosure | module Udata |
| backing slot 0 → proxy Udata | backing Table |
| backing positive slot → collectable element | backing Table |
| compiler slot → backing Table | the existing module/record/closure owner |

The hot element store barriers `obj2gco(backing)`, never the proxy. The proxy
fields are written directly with Lua-internal stores and barriers
(`titan_array_new_impl`), not through the public userdata API.

Each module creates its writer closures once at initialization:
`coder._emit_array_writers` (`titan-compiler/coder/values.lua`) builds each one
with `lua_pushcclosure(L, NAME, 1)` over `_mod` and caches it in a module user
value with the module's back barrier. `coder._array_writer`
(`titan-compiler/coder/names.lua`) deduplicates the inventory by element type,
so a module has one writer per constructed element type.

Across a resize, generated code roots the backing, a collectable right-hand
side, open constructor/result values, and any proxy needed by a boundary
conversion. Lua can relocate its stack during allocation, so saved stack
offsets are restored and raw stack-derived pointers are recomputed afterward.

## Authoritative `lenhint` and resizing

Lua 5.5 stores its table-length search hint in an unsigned word immediately
beside the array allocation. Titan uses that word as authoritative Array state
through `lenhint(t)`: `titan_array_length` dereferences it and
`titan_array_set_length` stores it. Generated `#array` reads the hint directly;
it never calls `luaH_getn`.

This matters because Lua treats `lenhint` as a mutable search cache:
`luaH_getn` may select any valid border in a holed ordinary table and write it
back. Titan instead maintains the highest-present-positive border after every
write:

- a non-nil write above length raises length to the index;
- a write below or at length otherwise leaves it unchanged;
- an interior nil write leaves length unchanged;
- deleting at exactly length scans backward over empty slots; and
- nil beyond capacity is a no-op.

`luaH_resizearray` internally resets the hint to `newasize / 2`. Therefore
`titan_array_resize` returns early when the capacity is unchanged, and otherwise
saves the logical length, calls the stock resize, and restores the length
immediately.

`titan_array_growth` selects the smallest power of two strictly greater than
the requested index in $O(1)$ with `__builtin_clzll`, and raises
`"array index too large"` above `TITAN_ARRAY_MAX_CAPACITY`. That macro
(`titan.h`) mirrors pinned Lua 5.5's private `MAXASIZE` expression.

### Structural validation

The boundary helpers are inline fast paths in `titan.h`:

- `titan_array_require_proxy(backing)` reads the proxy from slot 0 (debug
  assertions only);
- `titan_array_try_proxy(backing, metatable)` checks `asize > 0`, reads slot 0,
  and compares the proxy's metatable;
- `titan_array_try_proxy_either` accepts either canonical tag for nested and
  raw-backing recovery;
- `titan_array_try_backing(const TValue *, metatable)` and
  `titan_array_try_backing_either` test for a full userdata with the expected
  metatable and return `uv[0]`'s Table; and
- `titan_array_require_backing(const TValue *)` extracts `uv[0]` directly.

The nonthrowing backing probe is essential when a dynamic value happens to be
an ordinary Map Table: "not an Array backing" is a normal negative result, not
corruption.

Validation deliberately does not inspect user value 2. Only mutable
`__newindex` loads and invokes it for a non-nil Lua write; the const
constructor and freeze helper maintain the nil invariant. Supported code never
mutates either ownership link, the qualifier, or the writer. Debug-library or
C-level forgery is programmer-responsible; the helpers add no defensive checks
and do not repair damaged objects.

## Internal and boxed representations

The compiler distinguishes storage domains and qualifier by semantic Titan
type:

- `I(Array(T, isconst))` is compiler-owned typed/internal storage: a backing
  `Table *` or a Table-tagged `TValue`;
- `B(Array(T, isconst))` is Lua-canonical storage: the exact qualified proxy
  `Udata *` or a Udata-tagged `TValue`.

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

- `ctype(Type.Array)` is `Table *`, so exact signatures and out-parameters use
  `Table *` and `TitanVargArrayOrMap` uses `Table **`;
- typed slots use `hvalue`/`sethvalue`;
- `value` never carries a raw backing Table;
- Map storage boxes Array keys and values;
- record/module accessors box on get and unbox on set while their internal
  slots stay raw; and
- union construction/extraction keeps the backing Table in the part's assigned
  dense UV slot.

The shared `Table *` carrier never determines mutability. Boxing, unboxing,
strict guards, dynamic conversion, generic descriptors, and Interface field
adjustments select the mutable or const tag from `Type.Array.isconst`.

Array and Map share the C type `Table *`, while `Option(Array)`, `value`, and
Function can all use `TValue`. Representation selection therefore cannot
dispatch on C type alone; the coder uses semantically typed boxing, copying,
and mixed-read paths.

### Nested Array rule

A Titan write to `{ {T} }` stores the inner backing Table directly and barriers
outer backing → inner backing. Lua `__newindex` passes the incoming proxy
through the outer Array's writer; the writer validates and unboxes it and
returns the internal backing before the shared callback commits the store.

A typed nested read first accepts either structural backing tag, then recovers
the exact proxy required by the requested nested qualifier, through either a
structurally validated raw backing or a validated and unboxed canonical proxy.

An `{value}` read is different: an Array proxy inside the dynamic value stays
boxed. Ordinary Map Tables, including one with an unrelated key-0 entry, pass
through the nonthrowing probe unchanged.

## Checker elaboration

`Type.Array(elem, isconst)` requires the qualifier; `Type.Map(keys, values)`
is unqualified. Array equality, consistency, substitution, rewriting, erasure,
guard/dynamic plans, and serialization all retain the qualifier. Indexed reads
are optional; only mutable Array indices are lvalues.

Qualifier-crossing relations (mutable-to-const `array_freeze`, the
maybe-const `const? { T }` view and downcasts) and the linear-use proof that
selects an in-place freeze are in
[Const values](const-values.md#array-relations-and-linear-use-analysis); the
coder consumes the checker's plan and never recomputes escape or liveness
facts.

### Length operand types

The checker accepts as a `#` operand:

- String and the existing countable C types;
- Array; and
- Map only when its fully resolved key type is exactly `Type.Integer`.

It does not admit `value`, Float, a foreign C integer, or another key type as
an integer Map, and a metatable does not make a rejected Map key type
admissible. The distinction selects between the Array hint and
metamethod-aware ordinary-table length for a Map.

### Positional constructors

`Ast.ExpInitList` classifies fields as empty, all-positional, all-computed,
named, or invalid mixed forms. For an Array, or for a context whose exact type
is `Map(Integer, V)`, the checker:

1. derives the positional element/value context;
2. calls `adjust_explist` once;
3. checks/coerces each fixed scalar and open tail once;
4. preserves left-to-right evaluation, discard, and error order;
5. records the result as `_positional_adjustment`; and
6. for an Array, records the final element type, qualifier, and writer
   `DynamicCoercionPlan` (`annotate_array_writer` in
   `titan-compiler/checker/expression_lists.lua`, which sets
   `_array_writer_plan`). Mutable construction uses that plan as the future
   Lua writer policy; const construction installs no writer.

The annotation is representation-neutral: Array code generation creates the
backing/proxy pair, while positional integer-Map generation creates an ordinary
Table.

No-context positional construction defaults to Array. Empty `{}` can take any
context-provided Map type. Nonempty positional construction requires Array or
exact integer Map context. Computed keys stay scalar Map entries, named fields
stay record syntax, and mixed shapes produce deliberate diagnostics.

The adjusted final producer can be a fixed multiple return, flexible return,
contextual `value` call, input `...`, or a collection/ranged
[spread expression](spread-expressions.md). Its element adjustment is retained
on the open producer and consumed by code generation. Each actual result
consumes one position even when a `value`-consistent nil becomes an absent
table slot.

## Generated operations

### Array reads

`codeindexarray` (`titan-compiler/coder/expressions.lua`):

1. evaluates the backing and index once;
2. produces nil when the signed index is below 1;
3. otherwise converts the index to unsigned and, when it is below `asize`,
   reads array slot `k` with `arr2obj`, mapping an empty tag to nil; and
4. produces nil beyond capacity.

There is no hash lookup, allocation, registry lookup, metatable dispatch, or
length scan.

The static result is `Option(T)`. Its present arm uses the strict
`GuardPlan(T)` recorded in `_read_guard`: integer, float, and boolean require
their exact tags; C integer/float, C `TValue`, owned C userdata, nominal, and
nested container categories have explicit complete arms. Recursive Option
handling preserves nil and applies the same strict rule to a present value. It
never substitutes the broader numeric/truthiness `DynamicCoercionPlan`.

Storage-domain normalization is explicit: `Option(Array)` accepts nil, a
validated raw backing, or a validated proxy; `Option(value)` boxes an internal
Array but passes an ordinary Map through; `Option(Map)` accepts an ordinary
Table and rejects an Array proxy. The writer user value is neither read nor
compared.

### Array writes

The checker rejects an indexed lvalue whose Array type has
`isconst.tag ~= "no"` (`"cannot assign to an element of const Array"` in
`titan-compiler/checker/statements.lua`) before assignment bookkeeping.
Generated mutation code is therefore reachable only for a mutable Array, and
`coder._materialize_assignment_lvalue` asserts it.

`coder._materialize_array_lvalue` (`titan-compiler/coder/statements.lua`)
evaluates the Array and then the index exactly once and keeps the backing in a
scanned slot. `coder._codeadjustedfixed` then evaluates and roots the
right-hand value. Only afterward does `codeassignment` reject an index below 1,
convert it to unsigned, and mutate the backing. Multiple assignment freezes all
targets before any right-hand side and validates/stores left to right, so an
earlier store can commit before a later invalid Array index raises; see
[Code generator: constructs](codegen-constructs.md#locals-and-assignment).

An Array mutation then:

- writes nil in capacity or performs the tail backscan;
- treats nil beyond capacity as a no-op; or
- computes growth, preserves length across resize, refreshes relocated stack
  pointers, and writes the non-nil value.

The store uses `obj2arr` and barriers the backing Table for collectable values.
No user entry uses `luaH_setint`. The common in-capacity write has no proxy,
uservalue, or metatable load.

This is a Titan write through the current static view. It never invokes the
construction writer and therefore does not establish a heap invariant about all
slots. A write through `{value}` may make a later `{integer}` read fail its
strict guard; that checked failure is the gradual-view contract.

Lua writes go through `titan_array_lua_newindex` (`titan-runtime/titan.c`). It
validates the index first. Nil delegates directly to deletion (including the
allocation-free beyond-capacity no-op) and bypasses element conversion. For a
non-nil value it preflights oversized growth, calls proxy user value 2 with the
incoming value, and mutates the backing only after the writer returns the
converted slot. A conversion error therefore leaves capacity, length, and
contents unchanged. The rooted result survives any resize before
`titan_array_set_stack` commits it and applies the backing barrier.

### Constructors

The positional materializer preserves every fixed/open producer and roots its
values. Array lowering consumes the checker qualifier and element annotation,
computes the actual produced count, and validates exact capacity. A mutable
target reads its module-cached writer (`&_mod->uv[WRITER].uv`) and calls
`titan_array_new`; a const target calls `titan_const_array_new` with the const
metatable and no writer. Both copy positions into the array part, apply element
barriers, and record the highest non-nil position.

Positional integer-Map lowering reuses the expression-run adjustment but
allocates an ordinary Table, preallocates its array part to the produced count,
and assigns keys `1..N`. It has no explicit highest-present length. Keyed and
positional Map stores box an Array key or value before placing it in
raw-visible Map storage.

### Mutable-to-const lowering

A copy-mode `array_freeze` calls `titan_array_shallow_copy`. The helper asserts
the source's mutable canonical proxy, relies on the caller's distinct source
root across destination allocation, and publishes the destination backing into
the caller-provided result slot. The destination's array part has exactly the
source's physical `asize`. It copies only present slots through the source's
logical length, barriers every collectable destination value, and then sets
that logical length. Spare capacity stays empty; holes and trailing-length
semantics are preserved. It allocates, so the caller restores `_base`
afterward.

A checker-proven freeze-mode plan calls `titan_array_freeze`. It validates the
mutable proxy with debug assertions, writes the const canonical metatable
directly with `luaC_objbarrier` and `luaC_checkfinalizer`, clears user value 2
to nil, and returns the unchanged `Table *`. It does not allocate. Neither
helper performs an element conversion or changes `L->top`. The in-place path is
sound only because the checker proved that no mutable reference remains
observable. Both templates are in `titan-compiler/coder/expressions.lua`.

### Length

Array `#` uses `titan_array_length` and is entirely separate from Map
metamethod dispatch. Integer-Map length is generated by `code_map_length`; see
[Code generator: constructs](codegen-constructs.md#length-code_map_length).

## Exact and generic call paths

An Array-typed exact/native edge passes the backing pointer directly:

```text
argument/result/local/out: Table *
variadic/flexible element buffer: Table **
descriptor: TitanVargArrayOrMap
```

Lua entries, contextual calls through `value`, branded exact-tag-mismatch
function calls, raw Map storage, and exported accessors are boxed boundaries.
Outgoing Arrays become proxies selected by `Type.Array.isconst`; incoming Array
positions require and unwrap the exact target-qualified canonical proxy.
Options apply the selected strict or dynamic policy recursively. A
callable-adjustment wrapper's native adapter applies the same strict component
boxing and unboxing ([Closure adjustment wrappers](closure-adjustment-wrappers.md#wrapper-layout)).
No call route changes an Array's qualifier or compares or replaces its mutable
writer.

Dispatch is based on semantic Titan type, not descriptor family:
`TitanVargArrayOrMap` cannot reveal whether a `Table **` element is an Array
that needs boxing or a Map that must stay a Table, and a `TValue *` cannot
distinguish `Option(Array)` from `value`.

An exact call can still box because its *declared* type is `value` or because
it stores an Array in a Map. That is a boxed storage boundary, not an
Array-typed call edge.

## Standalone arguments

Standalone `main(args: {string}): integer` uses the ordinary Array constructor.
The entrypoint template in `driver.entrypoint_contents`
(`titan-compiler/driver.lua`, `pmain`) builds a fixed `{string}` writer,
`titan_main_string_array_writer`, as a C closure whose one upvalue is the
private lightuserdata key `titan_main_array_writer_key`; no per-type writer
registry is involved. It keeps the writer rooted on the Lua stack while
`titan_array_new` publishes the backing into a separate traced result slot,
then replaces that slot with the proxy before allocating argument strings.
Startup stores `argv[1..argc-1]` at positions `1..argc-1` with
`titan_array_set_stack`, sets length to `argc - 1`, and never writes user data
at slot 0.

The proxy goes to `main`'s Lua entry, directly or through the private
`titan.async` bootstrap hook, which validates and unboxes it before calling the
exact native `main` with `Table *`. Consequently the executable name is not in
the Array, `args[0]` is nil, and `#args == argc - 1`.

## ABI boundary

The compiled-module ABI ([Code generator overview](codegen-overview.md#compiled-module-abi))
covers this representation contract, not only the `Table *` signatures: the
boolean-qualified Array descriptor, the distinct const tag and metatable pair,
module-cached writers, and the exported construction, copy, and freeze helpers.
Code built against a different contract could treat `lenhint` as a border
cache, touch slot 0, or expose raw backings at Lua boundaries, so a mismatched
provider is rejected before any Array crosses it.

Interface satisfaction is an outer scalar coercion: it does not make `{R}` and
`{I}` consistent, and typed Array reads accept only an already wrapped exact
Interface element.

## Failure and performance boundaries

- Positive read and in-capacity write are O(1) direct slot operations.
- `#array` is O(1).
- Growth is amortized and preserves slot 0 and length.
- Tail deletion is O(1) without preceding holes and O(n) when it must scan
  backward over them.
- Boxing, unboxing, and structural validation are O(1) boundary operations.
- Every Array pays for one Udata with two user values and one array slot (slot
  0) in addition to its element storage. A mutable Array also references its
  module's cached writer closure for the element type; a const Array's second
  user value is nil.
- Shallow copy is O(source physical capacity allocation plus logical-range
  copying); a proven linear freeze is O(1).
- Oversized construction or growth fails before narrowing or Table overflow.
- There is no shrinking resize.

### Raw and stock table-library boundary

A Titan Array is table-like but not a Lua Table. Lua's `rawget`, `rawset`, and
`rawlen` reject the proxy as a non-Table. Stock Lua 5.5's `table` library is
different: its `checktab` path accepts a non-table whose raw metatable provides
the required `__index`, `__newindex`, and `__len` fields. Applicable `table.*`
operations therefore run through mutable proxy callbacks. A const proxy has
only `__index`/`__len`, so read-only operations work while a mutating operation
fails. This is stock behavior, not a Titan wrapper or Lua patch.

The debug library and C API can reveal or corrupt the private cycle, writer
user value, and `lenhint`. Preserving Titan invariants is the programmer's
responsibility when using those privileged APIs. Titan adds no writer
validation on the hot read path, state marker, special table flag, custom
collector hook, or recovery path.

## Tests

- `spec/dense_array_runtime_spec.lua` compiles the runtime against pinned stock
  Lua internals: capacities, growth, slot-0 survival, hint restoration,
  holes, tail backscan, writer dispatch and nil bypass, shallow copy and
  freeze, incremental/generational cycle collection, barriers, state close, and
  a `HARDMEMTESTS`/API-check construction proof.
- `spec/checker/dense_arrays_spec.lua` and `spec/coder/dense_arrays_spec.lua`
  cover module-local writer caching, strict reads versus coercive Lua writes,
  const write rejection, qualifier-exact dynamic views, open constructors,
  C-valued elements, `table.*` behavior, and multi-module construction.
- The const-value checker and coder suites cover written casts and linear
  builder elision.
