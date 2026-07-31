# Arrays and maps

Titan has two structural container types:

- an **Array**, written `{T}`, is a positive-integer-indexed sequence that may
  contain holes; and
- a **Map**, written `{K: V}`, is an ordinary Lua-style key/value dictionary.

They use different run-time protocols and are never interchangeable merely
because both contain indexed values. Gradual consistency descends only between
the same container kind: `{value}` is consistent with `{integer}`, but neither
is consistent with `{integer: value}`. This does not lift ordinary
conversions: `{integer}` cannot be used as `{float}` merely because one
integer can be converted to one float, and `{R}` cannot be used as `{I}`
merely because record or union `R` directly satisfies Interface `I`.

The distinction is visible at the Lua boundary. A Map is an ordinary Lua
table. An Array has a private Lua table backing its fast native operations and
a canonical userdata proxy for Lua, `value`, and raw-visible Map storage. The
proxy preserves one Array identity without exposing the private backing table.

## Arrays

### Type and element reads

`{T}` is the type of Arrays whose elements have type `T`. Container types can
nest:

```titan
local rows: {{integer}} = { {1, 2}, {3, 4} }
local indexes: {{string: integer}} = {
    { ["one"] = 1 },
    { ["two"] = 2 },
}
```

An element type is de-optionized. `{integer?}` denotes the same type as
`{integer}` because absence is already represented by the indexed read's
option type. If `a` has type `{T}`, `a[i]` has type `T?`: a missing position
returns nil. A plain `T` context checks that the value is present, while an
option declaration, condition, or `or` default can preserve or handle nil:

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
For an Interface element type, that strict guard requires an existing wrapper
of the exact nominal Interface type; it never wraps a bare record or union
found in the slot.

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
local floats: {float} = {1, 2, 3}  -- each value is converted to float
local inferred = {10, 20}          -- {integer}
local empty = {}                   -- no context: {integer}
```

An expected Array type supplies the element type. Without one, Titan infers
the element type from the positional expressions; an empty constructor falls
back to `{integer}`. Each source expression evaluates exactly once, from left
to right, and its conversion or error occurs before the next expression.

The final position is an open result consumer:

- an earlier expression or a parenthesized call contributes one position;
- a final fixed-multiple-return call contributes its visible results;
- a final flexible-return call or contextual call through `value` contributes
  the values actually returned; and
- a trailing input `...` contributes its complete run.

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

Array equality compares identity. Two separately constructed Arrays with the
same elements are unequal; repeated passage through Lua or `value` preserves
the same identity.

Nested Arrays preserve the same rule. Titan's native path can keep an inner
Array in its private form, while Lua sees the canonical inner proxy:

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
ordinary Map: it has Lua table-border length semantics, no Array proxy, and no
reserved key.

Classification is intentionally strict:

- `{}` is valid for a context-typed Map of any key type;
- nonempty positional fields require the exact Titan `integer` key type;
- `[key] = value` selects keyed Map construction;
- `name = value` selects record construction; and
- positional, computed-key, and named fields cannot be mixed.

A trailing input `...` is accepted by an Array or positional integer-Map, but
not by a keyed Map or record constructor.

### Reads, writes, and deletion

Map indexing converts the query key to `K` and returns `V?`. Every present
value is checked with the same strict target guard as an Array element before
Titan uses it. Writing from typed Titan code adjusts both the key and value;
writing nil deletes the entry:

```titan
function bump(m: {string: integer}, key: string): integer
    m[key] = (m[key] or 0) + 1
    return m[key]
end

function forget(m: {string: integer}, key: string)
    m[key] = nil
end
```

Maps use raw Lua table operations. A metatable attached by Lua does not make
Titan Map indexing dispatch `__index` or `__newindex`.

Because the Map is the ordinary table, raw Lua code can mutate it without an
intercepting writer. Titan does not add an origin bit, a proxy, or provenance
tracking. A later typed read is therefore strict regardless of whether the
slot came from exact Titan code, a Titan `{value}` view, or Lua. For example,
a Lua float `2.0` stored into a `{string: integer}` Map raises when Titan reads
it as `integer`; the read does not apply the integral-float dynamic coercion.
Likewise, a bare record stored by Lua in a Map whose value view is an Interface
raises on the later typed read rather than being wrapped.
This asymmetry is deliberate: genuine-Lua function arguments and intercepted
Array writes are dynamic boundaries, while raw Map mutation is followed only
by a strict typed observation.

As with Arrays, an unguardable value type makes the indexing expression a
compile-time error. A `{string: *c.T}` Map may be constructed or written from
statically typed Titan code, but `m[key]` through that raw-pointer value view is
rejected because lightuserdata cannot prove the pointee type.

### Integer-Map length

`#m` is accepted only when the resolved Map key type is exactly Titan
`integer`. It returns a valid Lua table border:

```titan
local m: {integer: string} = {"a", "b", "c"}
assert(#m == 3)
m[2] = nil
local border = #m  -- a valid Lua border; which one is unspecified
```

For a holed integer Map, the selected border has Lua's usual unspecified
semantics. This is different from deterministic Array length. Maps keyed by
`float`, `value`, strings, records, foreign integers, or any other type do not
support `#`, even when some run-time keys happen to be integers. Titan uses the
raw table-border operation; a Map's `__len` metamethod is not invoked.

## Lua representation and interoperation

At a Lua-visible boundary the two container kinds are deliberately distinct:

| Titan value | Lua representation |
| --- | --- |
| Array `{T}` | canonical full-userdata proxy |
| Map `{K: V}` | ordinary Lua table |
| `T?` containing an Array | nil or the canonical proxy |
| `value` containing an Array | canonical proxy |

Every Array backing/proxy pair is one-to-one. All Arrays in one Lua state use
one shared protected proxy metatable, so checking the outer Array kind remains
a direct metatable-identity test rather than a per-element type lookup.
Passing an Array repeatedly through module fields, record fields, union
payloads, functions, `value`, imports, nested boxes, or Lua returns preserves
the same proxy identity and construction policy. Map keys and values are
Lua-visible storage, so an Array stored in a Map is stored as that proxy,
never as its private table.

The boundary conversion rules are:

| From | To | Result |
| --- | --- | --- |
| Array | `value` or Lua | canonical proxy |
| Map | `value` or Lua | ordinary table |
| `value` containing canonical proxy | Array | succeeds, preserving identity |
| `value` containing plain table | Array | run-time type error |
| `value` containing plain table | Map | succeeds after the table check |
| `value` containing Array proxy | Map | run-time type error |
| Array | Map | statically rejected |
| Map | Array | statically rejected |

There is no direct Array-to-Map or Map-to-Array cast. A plain Lua table is a
valid Map input but is not an Array. To call an Array-typed Titan function
from Lua, obtain an Array proxy from Titan—for example from a factory or
exported Array—and pass that proxy back.

Lua indexing the proxy requires an integral numeric key. Numeric strings and
fractional numbers raise. Reads below 1 return nil; writes below 1 raise.

Every Array proxy carries the dynamic conversion policy chosen by the
Array's construction-time, context-adjusted element type. A genuine-Lua
non-nil write runs that policy before mutation. Thus an Array constructed as
`{integer}` accepts `2.0` from Lua and stores the converted integer, applies
truthiness for a `boolean` element, and rejects values that the canonical
dynamic conversion cannot produce. Function arguments, exported
module-variable writes, public record-field writes, and non-Titan Lua callable
results use the exact same target rules; see the
[normative boundary matrix](types.md#normative-boundary-matrix).
For an Interface element type, the writer accepts only an existing exact
Interface wrapper; a bare satisfying record or union from Lua is rejected.

Writing nil is deletion and bypasses the writer entirely. If a non-nil
conversion fails, capacity, deterministic length, and existing contents are
unchanged. Titan-origin writes do not invoke this Lua writer: their
checker-selected static adjustment applies at the Titan store, and any later
typed view still pays its strict read guard. The writer is therefore a policy
for future genuine-Lua writes, not evidence that every current element has one
particular type.

The representation that carries this policy is fixed:

* the private backing table's reserved key 0 points to the canonical proxy;
* proxy user value 1 points back to the backing table; and
* proxy user value 2 holds the constructing module's writer closure.

Each module generates and caches the closures needed by the Array types it
actually constructs. There is no global writer registry, no writer interning,
no “first one wins” rule, and no writer-identity comparison when a static view
changes. The closure retains its constructing module when nominal or foreign
conversion data is needed. Standalone programs similarly construct their
`main(args: {string})` Array with a fixed string writer.

### Raw and stock table-library behavior

An Array is table-like, but it is not a Lua table. `type(array)` is
`"userdata"` and `getmetatable(array)` returns the protected string
`"Titan array metatable"`. Lua's `rawget`, `rawset`, and base-library
`rawlen` reject the proxy because it is not a table. `pairs` support is not
promised because the proxy has no `__pairs`.

**Stock Lua 5.5 table-library reality.** Its `table` library deliberately
accepts a non-table object when the object's raw metatable supplies the
operations a function needs. Because an Array proxy necessarily supplies
`__index`, `__newindex`, and `__len`, applicable functions such as
`table.insert`, `table.remove`, `table.move`, `table.sort`, `table.concat`, and
`table.unpack` operate through those callbacks rather than rejecting the
proxy. Their effects therefore use the same positive-index and deterministic
length transitions and the construction-time dynamic writer. A later typed
read still performs its independent strict target guard. This differs from
the raw functions above, which do reject.

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
They do not perform a hash lookup, metatable dispatch, registry lookup, or
length scan. In particular, a typed read never loads or compares the writer;
the shared proxy metatable remains the fast outer tag even for nested Arrays.
`#array` is O(1). Growth is amortized; a tail deletion may scan backward over
holes. The Array's one private hash entry, proxy, second user-value slot, and
GC edge to the writer (and through it, when needed, the constructing module)
add a fixed per-Array ownership cost.

Map operations use Lua's specialized raw table paths selected from the static
key type. Positional integer-Map construction preallocates the ordinary table
array part, but it does not acquire deterministic Array semantics.

Exact Titan-to-Titan Array calls pass the private native identity directly.
An Array stored as a union payload likewise stays in Titan's internal
`Table *` representation until a real Lua or `value` boundary needs the
canonical proxy; case extraction does not manufacture a second proxy.
Lua, `value`, Map storage, and other generic boundaries pay a constant-time
proxy validation or lookup. See [Dense Arrays](../implementation/dense-arrays.md)
for the backing/proxy protocol, GC barriers, and lowering details.

The second proxy user value is an ABI change in Titan 0.20. Providers from ABI
0.17 through 0.19 use the earlier one-user-value Array layout and must be
rejected by the ordinary compiled-provider ABI check before either side
exchanges an Array; Titan does not attempt an in-place compatibility shim.
