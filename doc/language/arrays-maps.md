# Arrays and maps

Titan has two structural container families:

- a mutable **Array**, written `{T}`, or const Array, written `const { T }`, is
  a positive-integer-indexed sequence that may contain holes; and
- a **Map**, written `{K: V}`, is an ordinary Lua-style key/value dictionary.

They use different run-time protocols and are never interchangeable merely
because both contain indexed values. Gradual consistency descends only between
the same container kind and, for Arrays, the same qualifier: `{value}` is
consistent with `{integer}` and `const { value }` with
`const { integer }`, but mutable and const Arrays are not consistent with each
other and neither is consistent with `{integer: value}`. This does not lift ordinary
conversions: `{integer}` cannot be used as `{float}` merely because one
integer can be converted to one float, and `{R}` cannot be used as `{I}`
merely because record or union `R` directly satisfies Interface `I`.

The distinction is visible at the Lua boundary. A Map is an ordinary Lua
table. An Array has a private Lua table backing its fast native operations and
a canonical userdata proxy for Lua, `value`, and raw-visible Map storage. The
proxy preserves one Array identity without exposing the private backing table.

## Arrays

### Type and element reads

`{T}` is the type of mutable Arrays whose elements have type `T`;
`const { T }` is the corresponding read-only container type. Container types
can nest:

```titan
local rows: {{integer}} = { {1, 2}, {3, 4} }
local frozen_rows: {const { integer }} = { {1, 2}, {3, 4} }
local indexes: {{string: integer}} = {
    { ["one"] = 1 },
    { ["two"] = 2 },
}
```

An element type is de-optionized. `{integer?}` denotes the same type as
`{integer}` because absence is already represented by the indexed read's
option type. If `a` has type `{T}`, `a[i]` has type `T?`: a missing position
returns nil. A plain `T` context checks that the value is present, while an
option declaration, condition, or `or` default can preserve or handle nil.
The same read type and guard apply to `const { T }`:

```titan
function read(a: {integer}, i: integer): integer
    local checked = a[i]       -- integer; raises if the position is absent
    local optional? = a[i]     -- integer?; may be nil
    return optional or checked
end
```

See [Option types](option-types.md) for the general nil-flow rules.

Every present element is also checked with the **strict gradual guard** for
`T` before typed Titan code uses it. This remains true after an Array has
passed through `{value}`, `value`, Lua, an import, or a nested container.
Strict means that an integer slot requires an actual Lua integer, a float slot
an actual Lua float, and a boolean slot an actual boolean; a typed read does
not narrow an integral float, promote an integer, apply truthiness, introduce
or force an Option, or assert a raw C pointer. It either produces `T` or raises
before native code sees a value of the wrong representation.
For an Interface element type, that strict guard first accepts an existing
exact wrapper. It may also wrap bare full userdata when its metatable has a
compiler-witnessed entry for the target Interface; it does not inspect methods
or infer structural satisfaction from the stored value.

The checker must be able to build that guard. If `T?` is not guardable, the
indexing expression is rejected at compile time rather than compiled as an
operation that can only fail. Raw C pointers are the current important case:
an Array type containing one can be written as a type, but reading an element
through that view is rejected. Constructing such an Array is also rejected
because every Array construction must install a sound writer for future
genuine-Lua writes.

```titan
function replace(a: {value})
    a[1] = 2.0
end

function checked(): integer
    local a: {integer} = {1}
    replace(a)             -- a gradual view, not an element conversion
    return a[1]            -- raises: the stored value is a float
end
```

The same strict-observation rule applies to Maps and is defined centrally in
the [normative boundary matrix](types.md#normative-boundary-matrix).

### Positional constructors

A positional brace constructor builds an Array unless context requires an
integer-keyed Map:

```titan
local primes: {integer} = {2, 3, 5, 7}
local fixed: const { integer } = {2, 3, 5, 7}
local floats: {float} = {1, 2, 3}  -- each value is converted to float
local inferred = {10, 20}          -- {integer}
local empty = {}                   -- no context: {integer}
```

An expected Array type supplies both the element type and qualifier, so the
`fixed` constructor above creates a const proxy directly rather than first
building and copying a mutable one. Without context, Titan infers a mutable
Array from the positional expressions; an empty constructor falls back to
`{integer}`. Each source expression evaluates exactly once, from left to right,
and its conversion or error occurs before the next expression.

The final position is an open result consumer:

- an earlier expression or a parenthesized call contributes one position;
- a final fixed-multiple-return call contributes its visible results;
- a final flexible-return call or contextual call through `value` contributes
  the values actually returned;
- a trailing input `...` contributes its complete run;
- and a final [spread expression](spread-expressions.md) contributes all or a
  closed range of an Array, integer-Map, or variadic subject.

```titan
function pair(): (integer, integer)
    return 20, 30
end

function collect(prefix: integer, ...: integer): {integer}
    return {prefix, pair(), ...}
    -- pair() is not final, so this starts with prefix, 20, then the ... run
end
```

Every produced result consumes one sequential position, including a nil that
the target element type accepts. This matters for `{value}`:

```titan
local a: {value} = {1, nil, 3}  -- positions 1 and 3 present; #a == 3
local b: {value} = {1, 2, nil}  -- position 3 absent; #b == 2
local c: {value} = {nil}        -- capacity exists privately; #c == 0
```

An explicit nil remains invalid in `{integer}` or another non-nil element
type. A dynamic nil converted to that type raises the ordinary type error.
The constructor's storage capacity is not observable in Titan source.

### Positive indices

Array indices are positive integers. An integral float such as `2.0` is
accepted after a checked conversion; a non-integral number raises. A
non-numeric index is a compile-time error in Titan and a run-time error when
Lua indexes the proxy.

Reads below 1 are deliberately harmless:

```titan
assert(a[0] == nil)
assert(a[-1] == nil)
```

A read beyond the allocated storage also returns nil. A write below 1 raises
a positive-index error before it changes the Array (Titan source reports
`array index must be positive`; the Lua proxy reports
`Titan array index must be positive`). Thus key 0 is not a user position,
negative entries cannot be retained, and no Array operation falls back to a
hash entry.

Indexed assignment requires a mutable `{T}` receiver. Every indexed assignment
through `const { T }` is a compile-time error; Lua writes through its const
proxy fail at run time without changing the Array.

For a single `base()[index()] = rhs()` assignment, Titan evaluates the Array
expression, index expression, and right-hand expression exactly once in that
order; positive-index validation and mutation follow the right-hand side. In
a [multiple assignment](statements.md#multiple-assignment), all effectful
components of every target are frozen in lexical left-hand order before any
right-hand expression, and the stores then proceed left to right.

Writing nil deletes a position. Writing nil beyond the current capacity is an
allocation-free no-op:

```titan
local a: {value} = {10, 20, 30}
a[2] = nil
assert(a[2] == nil)
a[1000] = nil  -- still no position 1000 and no growth
```

Writing a non-nil value beyond capacity grows the private array storage to the
smallest power of two strictly greater than the requested logical index.
For an out-of-capacity write, indices 1, 2, 3, 4, and 5 therefore select
capacities 2, 4, 4, 8, and 8. Constructors can preallocate an exact
non-power-of-two position count, so a three-position constructor has capacity
3 and a later write at index 4 grows to 8. Capacity does not shrink.

Titan checks the pinned Lua 5.5 array-size bound before narrowing the index or
allocating. A non-nil write that cannot be represented raises
`array index too large`; it never creates a positive hash entry or silently
wraps to another index.

### Deterministic length and holes

`#a` is the greatest positive integer index whose value is non-nil, or zero
when no positive position is present. It is not an element count and is not
Lua's unspecified choice among several table borders:

```titan
local a: {value} = {10, 20, 30}
a[2] = nil
assert(#a == 3)  -- position 3 is still present
a[3] = nil
assert(#a == 1)  -- the tail scan crosses the hole at 2
a[1] = nil
assert(#a == 0)
```

Filling an interior hole does not change the length. A non-nil write above the
length raises it to that index. Deleting the final present position scans
backward to the preceding non-nil position or zero. Consequently `#a` is O(1)
and ordinary repeated `a[#a] = nil` is amortized O(1), but deleting a tail
after a long run of holes can take O(n).

This deterministic rule also applies to `#array` from Lua through the proxy's
`__len` operation. `ipairs(array)` still stops at the first nil, because
`ipairs` describes a contiguous prefix rather than Titan's highest-present
length.

### Identity and nested Arrays

Array equality compares identity within one qualifier. Two separately
constructed Arrays with the same elements are unequal; repeated passage
through Lua or `value` preserves the same identity and qualifier. Mutable and
const Array types are directly incomparable; cast both explicitly to `value`
when boxed identity comparison is intended.

Nested mutable and const Arrays preserve the same rule and their exact
qualifier. Titan's native path can keep an inner Array in its private form,
while Lua sees the corresponding canonical inner proxy:

```titan
function nested(): {{integer}}
    return { {1, 2}, {3, 4} }
end
```

```lua
local rows = require("rows").nested()
assert(type(rows) == "userdata")
assert(type(rows[1]) == "userdata")
assert(rows[1] == rows[1])
```

An Array of `value` does not implicitly unwrap an Array proxy held as a
dynamic value. The proxy is the canonical representation of that `value`.

### Const conversion and linear copy elision

There is no implicit qualifier change. The written cast from mutable `{S}` to
`const { T }` is admitted only when `S` and `T` are equal or gradually
consistent, and it makes a shallow copy that preserves logical length, holes,
and element identities:

```titan
function snapshot(values: {string}): const { string }
    return values as const { string }
end
```

It does not run numeric, nominal, or other per-element conversions.
Const-to-mutable conversion is rejected, including after a `value` round trip.
The two qualifiers have distinct exact run-time tags. A statically admitted
`array is const { T }` evaluates the mutable source once and returns true
without performing the cast; a test from `value` checks the exact qualified
tag.

The observable semantics are always the shallow copy. The compiler may retag
the source in place when it proves that one un-rebound local owns a fresh
mutable Array, the terminal cast is its last use, and the Array never escapes.
Before that cast, loops and structured builder logic may use `#array` and
indexed reads or writes. Calls may compute element values, and creating a
closure that does not reference the Array is harmless. Passing the Array to a
call, returning or storing it, making an alias, rebinding it, actually
capturing it in a closure, hiding the cast inside control flow, or using the
source or an alias afterward retains the copy path. Programs cannot observe
which lowering was selected.

See [Const values](const-values.md#const-arrays) for the complete qualifier
rules.

## Maps

### Type, keyed constructors, and keys

`{K: V}` maps keys of type `K` to values of type `V`:

```titan
local counts: {string: integer} = {}
local groups: {integer: {string}} = {}
```

As for Arrays, the value type is de-optionized and a read has type `V?`.
Map keys may be any Titan type except `nil` and option types. Arrays, Maps,
records, unions, Interfaces, and other identity-bearing values can be keys. A
union key uses the identity of the constructed union value, not its
variant/payload contents. An Array key uses its canonical identity, so the same
Array reaches the same entry across exact, `value`, and Lua paths.

An Interface key has the identity of its wrapper, not of the retained concrete
value. For a value `r: R` where `R` satisfies `I`, every `R -> I` conversion
constructs a fresh wrapper, so separately evaluating the concrete key for
insertion and lookup normally uses two different keys:

```titan
local by_interface: {I: string} = {}
by_interface[r] = "stored"       -- one fresh wrapper
local missed? = by_interface[r]  -- another wrapper; normally nil

local key: I = r
by_interface[key] = "shared"
local found? = by_interface[key] -- the same wrapper identity
```

Retain and reuse the Interface value when wrapper identity is intended to be
the key. See [Interfaces](interfaces.md#no-container-or-callable-lifting).

A keyed Map constructor writes every key in brackets:

```titan
local ages = { ["Ana"] = 31, ["Bia"] = 27 }
local flags: {float: boolean} = { [2.5] = true, [3] = false }
```

`{name = value}` is record-constructor syntax, never a shorthand string Map
entry. Key and value expressions are scalar consumers: a multiple-return call
contributes only its first result. Numeric keys follow Lua normalization, so
an integral float key and its integer spelling designate the same entry.

### Positional integer-Map constructors

When context expects exactly `{integer: V}`, a nonempty all-positional
constructor builds a Map with sequential keys `1..N`:

```titan
local names: {integer: string} = {"Ada", "Grace", "Edsger"}
```

This path uses the same left-to-right and final-open-expression adjustment as
an Array constructor, converting each produced value to `V`. A nil accepted
by `V` consumes its position but stores no entry. The result remains an
ordinary Map: it has Lua table-length semantics (an ordinary border unless a
later metatable supplies `__len`), no Array proxy, and no reserved key.

Classification is intentionally strict:

- `{}` is valid for a context-typed Map of any key type;
- nonempty positional fields require the exact Titan `integer` key type;
- `[key] = value` selects keyed Map construction;
- `name = value` selects record construction; and
- positional, computed-key, and named fields cannot be mixed.

A trailing input `...` or [spread expression](spread-expressions.md) is
accepted by an Array or positional integer-Map, but not by a keyed Map or
record constructor.

### Reads, writes, and deletion

Map indexing converts the query key to `K` and returns `V?`. It first looks for
the key in the Map itself. A present entry is returned without consulting
`__index`; on a miss, an attached metatable's `__index` follows Lua's ordinary
table-indexing rules. The metamethod may be a function or another indexing
target, and redirections can continue through the usual chained lookup until
they produce a value, find no metamethod, raise, or reach Lua's chain-loop
limit.

Every result is checked with the same strict target guard as an Array element
before Titan uses it, whether it came from the Map's raw slot or from
`__index`. In particular, an `__index` result does not gain general dynamic
numeric or truthiness conversion: an `integer` value still requires an actual
Lua integer and a `float` requires an actual Lua float. Records and unions
require their exact nominal tag. The named Interface strict-guard exception
allows a compiler-witnessed metatable entry to construct a wrapper. A final nil
remains the ordinary absent `V?` result.

Writing from typed Titan code adjusts both the key and value. A present entry
is updated directly without consulting `__newindex`. For an absent key,
`__newindex` follows Lua's ordinary assignment rules: a function can intercept
the assignment, or another target can continue the assignment chain. With no
applicable metamethod, the value is stored in the Map itself. Thus writing nil
deletes a present entry, while an absent-key nil assignment can still be
observed by `__newindex`:

```titan
function bump(m: {string: integer}, key: string): integer
    m[key] = (m[key] or 0) + 1
    return m[key]
end

function forget(m: {string: integer}, key: string)
    m[key] = nil
end
```

Because the Map is the ordinary table, Lua's raw table operations can mutate
it without an intercepting Titan writer. A user-supplied `__newindex` is also
arbitrary Lua policy, not a Titan value converter. Titan does not add an origin
bit, a proxy, or provenance tracking. A later typed read is therefore strict
regardless of whether the observed value came from exact Titan code, a Titan
`{value}` view, raw Lua mutation, or `__index`. For example, a Lua float `2.0`
stored in or returned for a `{string: integer}` Map raises when Titan reads it
as `integer`; the read does not apply the integral-float dynamic coercion.
Likewise, a bare record supplied for a Map whose value view is an Interface is
wrapped on the typed read only when an initialized generated module has
advertised that exact concrete/Interface pair; otherwise it raises.
This asymmetry is deliberate: genuine-Lua function arguments and intercepted
Array writes are dynamic boundaries, while observing a Map value performs only
the strict typed guard.

As with Arrays, an unguardable value type makes the indexing expression a
compile-time error. A `{string: foreign *T}` Map may be constructed or written from
statically typed Titan code, but `m[key]` through that raw-pointer value view is
rejected because lightuserdata cannot prove the pointee type.

### Equality

Map equality follows Lua table equality for the combinations whose static
comparison includes a Map. Two references to the same Map are equal without
calling `__eq`. For distinct Map/Map operands, Lua selects the left Map's
`__eq`, or the right Map's when the left has none; with neither metamethod the
result is false. A metamethod result uses Lua truthiness, and `~=` negates the
same result.

The same rule applies to Map/`value` and `value`/Map comparisons when the
`value` actually contains a table. The raw equality check still happens first,
and a non-table `value` cannot trigger table equality. This exception is
deliberately tied to the statically known Map operand: `value`/`value`
comparison remains raw equality even when both dynamic values happen to hold
tables, so it never invokes `__eq`.

### Integer-Map length

`#m` is accepted only when the resolved Map key type is exactly Titan
`integer`. With no `__len` metamethod, it returns a valid Lua table border:

```titan
local m: {integer: string} = {"a", "b", "c"}
assert(#m == 3)
m[2] = nil
local border = #m  -- a valid Lua border; which one is unspecified
```

For a holed integer Map without `__len`, the selected border has Lua's usual
unspecified semantics. If a metatable supplies `__len`, Titan follows Lua and
uses that metamethod instead. Its result must have the exact Lua integer tag
promised by Titan's surface result type: an integral float such as `7.0`, a
string, or any other value raises a type error rather than being converted.

This is different from deterministic Array length. Maps keyed by `float`,
`value`, strings, records, foreign integers, or any other type do not support
`#`, even when some run-time keys happen to be integers. The metatable does not
broaden that static rule.

### Module-variable initializers

Map metatables also matter to the [initializer dependency
rule](modules.md#initializer-dependencies). A potentially metatable-bearing
Map read exposes its Map and key to `__index`; Map/Map or Map/`value`
comparison exposes both operands to `__eq`; integer-Map length and spread
expose their Map receiver to `__len` or `__index`. An own lambda, bound method,
or other own callable cannot reach these implicit calls during initialization,
even through a nested container or generated constructor.

Fresh ordinary Map literals have no metatable, and their entries are filled
with raw stores. Operations proved to stay on such fresh values remain legal,
including equality and length of callable-bearing literals. Casts and boxing
preserve their origin rather than introducing a metatable. Raw
`value`/`value` equality and canonical Array indexing/length do not acquire Map
dispatch. In every case, computations nested in the operands and any exposure
from an enclosing call are still checked.

## Lua representation and interoperation

At a Lua-visible boundary the two container kinds are deliberately distinct:

| Titan value | Lua representation |
| --- | --- |
| mutable Array `{T}` | canonical mutable full-userdata proxy |
| const Array `const { T }` | canonical const full-userdata proxy |
| Map `{K: V}` | ordinary Lua table |
| `T?` containing an Array | nil or its exact qualified proxy |
| `value` containing an Array | its exact qualified proxy |

Every Array backing/proxy pair is one-to-one. All Arrays in one Lua state use
one canonical protected mutable metatable and one canonical protected const
metatable. Checking the outer Array kind and qualifier is therefore a direct
metatable-identity test rather than a per-element type lookup. Passing an Array
repeatedly through module fields, record fields, union payloads, functions,
`value`, imports, nested boxes, or Lua returns preserves the same proxy
identity, qualifier, and construction policy. Map keys and values are
Lua-visible storage, so an Array stored in a Map is stored as that proxy, never
as its private table.

The boundary conversion rules are:

| From | To | Result |
| --- | --- | --- |
| mutable Array | `value` or Lua | canonical mutable proxy |
| const Array | `value` or Lua | canonical const proxy |
| Map | `value` or Lua | ordinary table |
| `value` containing exact target-qualified proxy | same-qualified Array | succeeds, preserving identity |
| `value` containing the other Array qualifier | Array | run-time type error |
| `value` containing plain table | Array | run-time type error |
| `value` containing plain table | Map | succeeds after the table check |
| `value` containing Array proxy | Map | run-time type error |
| Array | Map | statically rejected |
| Map | Array | statically rejected |

There is no direct Array-to-Map or Map-to-Array cast. A plain Lua table is a
valid Map input but is not an Array. Lua also cannot substitute a mutable proxy
for a const parameter, or vice versa. To call an Array-typed Titan function
from Lua, obtain the correct qualified Array proxy from Titan—for example from
a factory or exported Array—and pass that proxy back.

Lua indexing either proxy requires an integral numeric key. Numeric strings
and fractional numbers raise. Reads below 1 return nil; mutable writes below 1
raise, and every write through a const proxy raises before conversion or
mutation.

Every mutable Array proxy carries the dynamic conversion policy chosen by the
Array's construction-time, context-adjusted element type. A genuine-Lua
non-nil write runs that policy before mutation. Thus an Array constructed as
`{integer}` accepts `2.0` from Lua and stores the converted integer, applies
truthiness for a `boolean` element, and rejects values that the canonical
dynamic conversion cannot produce. Function arguments, exported
module-variable writes, public record-field writes, and non-Titan Lua callable
results use the exact same target rules; see the
[normative boundary matrix](types.md#normative-boundary-matrix).
For an Interface element type, the writer accepts an existing exact Interface
wrapper or calls a compiler-witnessed entry advertised on a bare full
userdata's metatable. A merely structurally satisfying record/union with no
loaded witness is rejected.

Writing nil is deletion and bypasses the writer entirely. If a non-nil
conversion fails, capacity, deterministic length, and existing contents are
unchanged. Titan-origin writes do not invoke this Lua writer: their
checker-selected static adjustment applies at the Titan store, and any later
typed view still pays its strict read guard. The writer is therefore a policy
for future genuine-Lua writes, not evidence that every current element has one
particular type.

The representations are fixed:

* the private backing table's reserved key 0 points to the canonical proxy;
* proxy user value 1 points back to the backing table;
* mutable proxy user value 2 holds the constructing module's writer closure;
  and
* const proxy user value 2 is nil.

Each module generates and caches the closures needed by the mutable Array types it
actually constructs. There is no global writer registry, no writer interning,
no “first one wins” rule, and no writer-identity comparison when a static view
changes. The closure retains its constructing module when nominal or foreign
conversion data is needed. Standalone programs similarly construct their
`main(args: {string})` Array with a fixed string writer.

### Raw and stock table-library behavior

An Array is table-like, but it is not a Lua table. `type(array)` is
`"userdata"` and `getmetatable(array)` returns the protected string for its
qualified Titan Array metatable. Lua's `rawget`, `rawset`, and base-library
`rawlen` reject the proxy because it is not a table. `pairs` support is not
promised because the proxy has no `__pairs`.

**Stock Lua 5.5 table-library reality.** Its `table` library deliberately
accepts a non-table object when the object's raw metatable supplies the
operations a function needs. A mutable Array supplies `__index`, `__newindex`,
and `__len`, so applicable functions such as `table.insert`, `table.remove`,
`table.move`, `table.sort`, `table.concat`, and `table.unpack` operate through
those callbacks. Their effects use the same positive-index and deterministic
length transitions and the construction-time dynamic writer. A const Array
supplies only `__index` and `__len`: read-only operations such as
`table.concat` and `table.unpack` can operate, while an operation that attempts
to mutate fails without changing the Array. A later typed read still performs
its independent strict target guard. This differs from the raw functions
above, which reject either proxy.

The Lua debug library can bypass metatable protection and expose or replace
either private user value. A C module can inspect or mutate Lua's internal
Table directly. Doing either deliberately leaves Titan's safety contract:
reading or changing the private backing table, key 0, either user value,
metatable, writer, or stored length is programmer-responsible and may violate
Titan invariants. The debug library is not available to untrusted code under
Titan's contract, and Titan does not add defensive checks for corruption
performed through it.

## Performance summary

Array positive reads and in-capacity writes are direct array-slot operations.
The outer backing-slot access and exact-guard fast paths do not perform a hash
lookup, metatable dispatch, registry lookup, or length scan. Const Arrays use
the same read and length paths and have no native write path. A witnessed
Interface element is the exception after the slot load: its strict guard
raw-looks up the candidate metatable and may enter the VM to construct a
wrapper. In every case, a typed read never loads or compares the writer; the
qualified proxy metatable remains the fast outer tag even for nested Arrays.
`#array` is O(1). Growth is amortized; a tail deletion may scan backward over
holes. The Array's one private hash entry, proxy, and second user-value slot
add a fixed per-Array ownership cost. A mutable Array additionally traces its
writer (and through it, when needed, the constructing module); a const Array's
writer slot is nil. A mutable-to-const copy is O(length), while a proven linear
freeze retags in constant time.

Map reads keep Lua's specialized raw table paths selected from the static key
type. A hit returns immediately; a miss normally ends after a cached
no-metatable/no-`__index` check, and only a possible metamethod enters Lua's VM
finish path. Map assignments likewise retain the direct raw store when there
is no metatable or no `__newindex`; with a possible metamethod they use Lua's
partial-set fast path so an existing entry is still updated inline, and enter
the VM finish path only for the unresolved case. Map constructors remain raw
stores into a fresh table. Equality keeps its identity/raw fast checks and
calls Lua's metamethod-aware equality only for the narrow Map cases described
above. Integer-Map length likewise uses the raw table-border path when cached
metamethod lookup proves `__len` absent and enters Lua's VM path only when it
may be present. These paths do not replace the whole operation with public
`lua_gettable`, `lua_settable`, or `lua_len` calls.

Positional integer-Map construction preallocates the ordinary table array
part, but it does not acquire deterministic Array semantics.

Exact Titan-to-Titan Array calls pass the private native identity directly.
An Array stored as a union payload likewise stays in Titan's internal
`Table *` representation until a real Lua or `value` boundary needs the
canonical proxy; case extraction does not manufacture a second proxy.
Lua, `value`, Map storage, and other generic boundaries pay a constant-time
proxy validation or lookup. See [Dense Arrays](../implementation/dense-arrays.md)
for the backing/proxy protocol, GC barriers, and lowering details.

ABI 2 includes the two-user-value proxy layout, a distinct const Array tag,
and a two-metatable module cache while retaining
the dense `Table *` backing and two-user-value proxy. The ordinary
compiled-provider ABI check rejects every mismatched provider before either side
exchanges an Array; Titan does not attempt an in-place compatibility shim.
