# Arrays, Maps, and Iteration

Titan provides two built-in container families:

- **Arrays** (`{T}`, `const { T }`, and `const? { T }`) are 1-based sequences indexed by positive integers, with deterministic length and support for holes.
- **Maps** (`{K: V}`) are general key/value dictionaries backed directly by ordinary Lua tables.

| Property | Array (`{T}`) | Map (`{K: V}`) |
| --- | --- | --- |
| Indexing | Positive integers (`1, 2, ...`) | Any key type except `nil` or `T?` |
| Read type | `T?` | `V?` |
| Writing `nil` | Deletes position | Deletes key |
| Length `#` | Highest present positive index (deterministic) | Exact `integer`-key Maps only (`__len` or Lua border) |
| Constructors | Positional `{a, b, c}` | Keyed `{ [k] = v }` (positional only for `{integer: V}`) |
| Lua representation | Canonical userdata proxy | Ordinary Lua table |

Arrays and Maps are distinct types and are never interchangeable. Gradual consistency descends only within the same container kind and Array qualifier: `{value}` is consistent with `{integer}` and `const { value }` with `const { integer }`, but mutable and const Arrays are not consistent with each other, and neither is consistent with `{integer: value}`. Scalar conversions do not lift through containers: `{integer}` cannot be passed where `{float}` is expected, and `{R}` cannot be passed where `{I}` is expected even when record `R` satisfies Interface `I`.

## Arrays

### Types, reads, and strict guards

`{T}` is a mutable Array of `T`. Container types may nest freely:

```titan
function nested_examples(): ({{integer}}, {const { integer }}, {{string: integer}})
    local rows: {{integer}} = { {1, 2}, {3, 4} }
    local fixed_rows: {const { integer }} = { {1, 2}, {3, 4} }
    local indexes: {{string: integer}} = {
        { ["one"] = 1 },
        { ["two"] = 2 },
    }
    return rows, fixed_rows, indexes
end
```

Element types are de-optionized: `{integer?}` is the same type as `{integer}`, because absence is already represented by the read's option type. Reading `a[i]` from `{T}` produces `T?`, returning `nil` when position `i` is absent. An ordinary inferred local forces presence and raises on `nil`; a trailing `?` preserves the option:

```titan
function read_or_default(values: {integer}, index: integer, fallback: integer): integer
    local optional? = values[index]     -- integer?; may be nil
    if optional ~= nil then
        return optional
    end
    return fallback
end

function read_required(values: {integer}, index: integer): integer
    local required = values[index]      -- integer; raises if position is absent
    return required
end
```

Every present element read is checked with Titan's **strict gradual guard** for `T`, even after the Array has passed through `{value}`, `value`, or Lua. An `integer` read requires an actual Lua integer, a `float` read requires an actual Lua float, and a `boolean` read requires an actual boolean—reads never narrow a float like `2.0` to an integer or apply truthiness:

```titan
local function overwrite_as_float(items: {value})
    items[1] = 2.0
end

function strict_read_demo(): integer
    local nums: {integer} = {1}
    overwrite_as_float(nums)            -- gradual view shares the same Array
    return nums[1]                      -- raises at run time: stored value is a float
end
```

For an Interface element type `I`, the strict read guard accepts an existing `I` wrapper or wraps bare userdata whose type has a compiled witness for `I` (see [Interfaces](interfaces.md)). Element types that cannot be guarded at run time—such as raw C pointers `foreign *T`—cannot be constructed or read as Arrays.

### Positional constructors

A positional brace constructor builds an Array unless context specifically expects an `{integer: V}` Map:

```titan
function pair(): (integer, integer)
    return 20, 30
end

function build_arrays(): ({integer}, {float}, {integer})
    local primes = {2, 3, 5, 7}         -- inferred as {integer}
    local floats: {float} = {1, 2, 3}   -- each integer converts to float
    local combined = {10, pair()}       -- final call expands: {10, 20, 30}
    return primes, floats, combined
end
```

Without a target type, Titan infers a mutable Array from its elements; an empty `{}` with no context defaults to `{integer}`. Expressions evaluate left-to-right, once each. Only the final position is an open consumer—expanding multiple returns, flexible returns, `...`, and spread expressions ([Functions, Arguments, and Results](functions.md)).

Every value produced in a positional constructor advances the index by one, including `nil` when the element type accepts it (such as `{value}`):

```titan
function sparse_lengths(): (integer, integer, integer)
    local a: {value} = {1, nil, 3}      -- positions 1 and 3 present; #a == 3
    local b: {value} = {1, 2, nil}      -- trailing nil is absent; #b == 2
    local c: {value} = {nil}            -- no present positions; #c == 0
    return #a, #b, #c
end
```

### Positive indices, deletion, and deterministic length

Array indices are positive integers starting at `1`. An integral float such as `2.0` is accepted via checked numeric conversion; fractional floats raise at run time, and non-numeric indices are compile-time errors.

- Reading at an index below `1` or past the end returns `nil`.
- Writing at an index below `1` raises a positive-index error without modifying the Array.
- Writing `nil` deletes that position. Writing `nil` past the current capacity is a no-op that does not allocate.
- Writing a non-nil value beyond current capacity grows the Array (raising `array index too large` if the index exceeds Lua's array-size limit).

For a single assignment `base()[index()] = rhs()`, Titan evaluates the Array, index, and right-hand value once each in that order before validating the index and storing.

`#a` is always the **greatest positive index holding a non-nil value**, or `0` if the Array is empty. Unlike Lua's table border `#`, Array length is deterministic even when interior holes exist:

```titan
function length_transitions(): (integer, integer, integer)
    local items = {10, 20, 30}
    items[2] = nil
    local with_hole = #items            -- 3: position 3 is still present

    items[3] = nil
    local after_tail_delete = #items    -- 1: tail scan skips the hole at 2

    items[1] = nil
    local empty = #items                -- 0
    return with_hole, after_tail_delete, empty
end
```

Filling an interior hole leaves `#a` unchanged. Deleting the highest present element scans backward to the previous present index (or `0`). Thus `#a` is O(1), repeated pop-from-end (`a[#a] = nil`) is amortized O(1), and deleting the tail after a long run of holes takes time proportional to the holes skipped.

### Identity

Arrays compare by reference identity within the same qualifier: two separately constructed Arrays with identical elements are unequal, and passing an Array through `value`, Lua, or nested containers preserves its identity. Mutable `{T}` and `const { T }` cannot be compared directly with `==`; cast both to `value` when comparing boxed identity.

## Read-only and maybe-const Arrays

### `const { T }`

`const { T }` is a read-only Array type. It supports indexed reads, deterministic `#`, holes, and strict element guards, while rejecting every indexed write at compile time (and from Lua at run time). Placing `const` before the braces keeps Array constness distinct from C pointer constness inside the element type. Maps do not have a `const` form.

A positional constructor in a `const { T }` target builds the read-only Array directly without constructing and copying a mutable one:

```titan
function small_primes(): const { integer }
    return {2, 3, 5, 7}
end
```

### Snapshotting and the builder-freeze idiom

In general, there is no implicit conversion between `{T}` and `const { T }`, and a `const { T }` can never be cast back to mutable `{T}` (even after a round trip through `value`). To obtain a `const { T }` from a mutable `{T}` whose element type is equal or gradually consistent, use `as const { T }`:

```titan
function snapshot(items: {string}): const { string }
    return items as const { string }
end
```

Semantically, `items as const { T }` creates a shallow copy preserving length, holes, and element identities (constness is shallow: reference-typed elements inside a `const` Array remain mutable through their own APIs). It does not run per-element numeric or nominal conversions. On a statically compatible mutable Array, `items is const { T }` evaluates `items` once and returns `true` without allocating.

In two common builder patterns, the compiler proves that the mutable Array is unaliased and freezes it in place in O(1) time with no copy:

1. **Local builder:** Create a fresh `{}` local, populate it using loops, `#`, and indexed reads/writes without passing, storing, aliasing, or capturing it, and cast it as the entire initializer of a single local (`local frozen = items as const { T }`) or as the entire `return` expression in that same block.
2. **Fresh-returning helper:** If an earlier function in the same module returns a fresh, unaliased mutable Array on every return path, assigning or casting its call result directly to `const { T }` freezes it in place without needing `as`:

```titan
local function build_squares(count: integer): {integer}
    local out: {integer} = {}
    for i = 1, count do
        out[i] = i * i
    end
    return out
end

function frozen_squares(count: integer): const { integer }
    local built: {integer} = {}
    for i = 1, count do
        built[i] = i * i
    end
    return built as const { integer }       -- frozen in place (local builder)
end

function caller_frozen(count: integer): const { integer }
    local result: const { integer } = build_squares(count) -- frozen in place
    return result
end
```

If the mutable Array escapes, is aliased, is used after the cast, or comes from a forward-declared or imported function, `as const { T }` performs the shallow copy. Programs cannot observe which path ran, because both produce the exact same read-only Array behavior.

### `const? { T }` (maybe-const views)

When a function only reads an Array, use `const? { T }` so callers can pass either mutable `{T}` or `const { T }` with zero overhead and no copying:

```titan
function sum(items: const? { integer }): integer
    local total = 0
    for i = 1, #items do
        total = total + (items[i] or 0)
    end
    return total
end

function sum_both(): integer
    local mutable = {1, 2, 3}
    local fixed: const { integer } = {4, 5, 6}
    return sum(mutable) + sum(fixed)
end
```

Rules for `const? { T }`:

- `{T}`, `const { T }`, and `const? { T }` all convert implicitly to `const? { T }` (for equal or gradually consistent element types). Options propagate the same way: `({T})?` and `(const { T })?` convert to `(const? { T })?`.
- `const? { T }` supports `#` and indexed reads, and rejects indexed writes at compile time. Passing an Array through `const? { T }` preserves the original mutable or const Array without copying or freezing it.
- `const? { T }` does not implicitly convert back to `{T}` or `const { T }`.
- Explicit runtime qualifier checks and downcasts inspect the Array's actual tag:
  - `xs is { T }` and `xs is const { T }` test whether `xs` is mutable or const without allocating.
  - `xs as { T }` succeeds if `xs` is mutable and raises a runtime error if `xs` is const.
  - `xs as const { T }` succeeds if `xs` is **already** const and raises a runtime error if `xs` is mutable. Unlike casting a known mutable `{T}`, casting `const? { T }` to `const { T }` is a qualifier check, not a shallow snapshot.

```titan
function append_if_mutable(items: const? { integer }, extra: integer): boolean
    if items is { integer } then
        local target = items as { integer }
        target[#target + 1] = extra
        return true
    end
    return false
end
```

## Maps

### Types, keys, and constructors

`{K: V}` maps keys of type `K` to values of type `V`. As with Arrays, the value type is de-optionized (`{string: integer?}` is `{string: integer}`) and every read returns `V?`.

Keys may be any Titan type except `nil` and Option types. Identity-bearing values—Arrays, Maps, records, unions, and Interfaces—are valid keys and compare by identity. Because every `R -> I` Interface conversion allocates a fresh wrapper, store the Interface wrapper in a variable before using it as a Map key (see [Interfaces](interfaces.md)).

Keyed Map constructors write every key inside brackets:

```titan
function sample_maps(): ({string: integer}, {float: boolean}, {string: integer})
    local ages = { ["Ana"] = 31, ["Bia"] = 27 }
    local flags: {float: boolean} = { [2.5] = true, [3] = false }
    local empty: {string: integer} = {}
    return ages, flags, empty
end
```

`{ name = value }` is record-constructor syntax, never a shorthand string Map entry. Key and value expressions are scalar consumers (only the first result of a multi-return call is kept), and numeric keys follow Lua's normalization so `3` and `3.0` name the same slot.

When context expects an exact `{integer: V}` Map, a nonempty positional constructor builds a Map with sequential keys `1..N` and accepts trailing multi-returns, `...`, and spreads just like an Array constructor:

```titan
function indexed_names(): {integer: string}
    local names: {integer: string} = { "Ada", "Grace", "Edsger" }
    return names
end
```

Positional, `[key] = value`, and record `name = value` entries cannot be mixed in one constructor.

### Reads, writes, deletion, and metatables

Map indexing converts the key to `K` and returns `V?`; writing `nil` deletes a key:

```titan
function bump(counts: {string: integer}, key: string): integer
    counts[key] = (counts[key] or 0) + 1
    return counts[key]
end

function forget(counts: {string: integer}, key: string)
    counts[key] = nil
end
```

Because a Map is an ordinary Lua table, it honors any metatable attached at the Lua boundary:

- **Reads (`m[k]`):** A raw hit returns immediately; a miss follows Lua's `__index` chain. Every non-nil result—whether raw or from `__index`—passes through the strict runtime guard for `V` (so a float `2.0` stored from Lua raises when read from `{string: integer}`). As with Arrays, unguardable value types such as `foreign *T` cannot be read through `m[k]`.
- **Writes (`m[k] = v`):** An already-present key updates or deletes directly without consulting `__newindex`. An absent key follows `__newindex` (including writing `nil` to an absent key).

### Equality and integer-Map length

Map equality (`==` and `~=`) follows Lua table equality whenever at least one static operand is a Map:

- Two references to the same table are equal without calling `__eq`.
- For distinct tables, Titan invokes the left operand's `__eq` (or the right's if the left has none) and converts its result by Lua truthiness.
- When comparing a Map with a `value`, `__eq` is consulted only if the `value` actually holds a table. Comparing two `value` operands uses raw equality and never calls `__eq`.

`#m` is allowed only when the Map's key type is exact `integer`. If a metatable defines `__len`, Titan invokes it and requires its return value to carry the exact Lua integer tag (otherwise raising a type error). Without `__len`, `#m` returns a valid Lua table border—which is unspecified when the integer keys contain holes.

In module-variable initializers, operations on a Map that could carry a metatable (reads, `#`, spreads, and Map equality) count as potential calls under the initializer dependency rules; operations on freshly constructed Map literals do not (see [Modules and Program Structure](modules.md)).

## Iterating over Arrays and Maps

For dense Arrays—and for `const { T }` or `const? { T }` views—use a numeric `for` loop from `1` to `#items`:

```titan
local strings = import "string"

function uppercase_all(input: const? { string }): {string}
    local output: {string} = {}
    for i = 1, #input do
        output[i] = strings.upper(input[i])
    end
    return output
end
```

When a mutable Array may contain holes, use `iteration.ipairs` from the `iteration` module. Unlike Lua's `ipairs`, `iteration.ipairs` visits every position from `1` through `#array` without stopping at holes, yielding a non-nil index and an optional `T?` element:

```titan
local iteration = import "iteration"

function count_present(items: {string}): integer
    local present = 0
    for _, item? in iteration.ipairs(items) do
        if item ~= nil then
            present = present + 1
        end
    end
    return present
end
```

For Maps, use `iteration.pairs` (or `iteration.next` directly) to visit every `(key, value)` pair in unspecified order:

```titan
local iteration = import "iteration"

function total_score(scores: {string: integer}): integer
    local total = 0
    for _, score in iteration.pairs(scores) do
        total = total + score
    end
    return total
end
```

See [Statements, Scope, and Control Flow](statements.md) for the generic `for` protocol and [Iteration](standard-library-iteration.md) for the full `iteration` API.

## Lua interoperability and performance

At the Lua boundary, Maps are plain Lua tables and Arrays are userdata proxies (`type(arr) == "userdata"`) with protected metatables:

| From | To | Result |
| --- | --- | --- |
| `{T}` / `const { T }` | Lua or `value` | Mutable / const userdata proxy |
| `{K: V}` | Lua or `value` | Ordinary Lua table |
| Lua table / `value` table | `{K: V}` | Accepted (checked as table) |
| Lua table / `value` table | `{T}` or `const { T }` | Runtime type error |
| Array proxy | `{K: V}` | Runtime type error |
| Wrong Array qualifier | `{T}` or `const { T }` | Runtime type error |

Key Lua-boundary behaviors:

- **Passing Arrays from Lua:** A plain Lua table is never accepted where a Titan Array is expected. Create the Array in Titan (or obtain an exported Array) and pass that proxy back.
- **Indexing and writing from Lua:** Indexing an Array proxy requires an integral numeric key; reads below `1` return `nil`; writes below `1` raise; every write through a `const` proxy raises. Non-nil Lua writes into a mutable Array run the dynamic conversion for the Array's construction-time element type (for example, an Array constructed as `{integer}` accepts `2.0` from Lua and stores integer `2`), while writing `nil` deletes directly.
- **Raw and `table.*` functions:** Because Array proxies are userdata, Lua's `rawget`, `rawset`, and `rawlen` reject them. Lua 5.5's `table` library works through metamethods: `table.concat` and `table.unpack` work on both mutable and const Arrays, while mutating functions (`table.insert`, `table.remove`, `table.move`, `table.sort`) work on mutable Arrays and fail on const Arrays.

### Performance characteristics

- **Arrays:** Positive reads and in-capacity writes compile to direct slot loads and stores without hashing or metatable dispatch. `#a` is O(1). Growth is amortized; deleting the tail scans backward over any trailing holes. `as const { T }` is O(length) when copying and O(1) when frozen in place.
- **Maps:** Reads, writes, `#`, and equality take direct raw table fast paths when no metatable or relevant metamethod is present, falling back to Lua's metamethod dispatch only when needed.
