# Arrays and maps

Titan has two container types: arrays, written `{T}`, and maps, written
`{K: V}`. At run time both are ordinary Lua tables — a Titan array or map
can be handed to Lua and back freely, and both sides see the very same
object — but the static type tells the compiler which face of the table
the code uses: an array is an integer-indexed sequence served by the
table's array part, a map is a general key–value dictionary served by its
hash part. Splitting Lua's single table type in two is a deliberate
design decision (see [the design philosophy](philosophy.md)).

Array and map types are *structural*: two array types are equal when
their element types are, and two map types are equal when their key and
value types are (see [the type system](types.md)). They also participate
in `value`-compatibility: a `{value}` can be used where a `{float}` is
expected and vice versa, with the element checks happening at the access
sites. [Records](records.md) are the third table-flavored construct in
Titan, but they are nominal and are *not* tables.

## Arrays

### The array type `{T}`

`{T}` is the type of arrays whose elements have type `T`, for any Titan
type `T` — including other containers, so `{{integer}}` is an array of
arrays of integers and `{ {string: float} }` is an array of maps.

The element type is always a plain, non-option type: the annotation
`{integer?}` is accepted by the compiler but denotes the same type as
`{integer}`. The option mark would add nothing, because element *reads*
already produce `integer?` (see below).

### Constructors

An array is created with a brace-enclosed list of expressions. Each
element expression is implicitly coerced to the element type under the
usual rules, so integer literals fill a float array; an element that
cannot be coerced is a compile-time error of the shape `types in array
initializer at position 2 do not match, expected integer but found
string`.

```lua
local primes: {integer} = {2, 3, 5, 7}
local grid: {{integer}} = { {1, 2}, {3, 4} }   -- containers nest
local xs: {float} = {1, 2, 3}                  -- stored as 1.0, 2.0, 3.0
```

The type of the constructor — most visibly of the empty constructor
`{}` — comes from the context: the type of the variable being assigned
or declared, the type of the parameter the constructor is passed to, the
declared return type, and so on. With no expected type, the element type
is inferred from the first element. With no context *and* no elements,
Titan falls back, as a last resort, to `{integer}`:

```lua
local names: {string} = {}   -- typed by the declaration
local ys = {1.5, 2.5}        -- inferred as {float} from the first element
local zs = {}                -- no context at all: defaults to {integer}
```

A function call in the *last* position of a constructor contributes all
of its return values; calls in earlier positions are truncated to one
value (see [Functions](functions.md) for the general rule):

```lua
function two(): (integer, integer)
    return 20, 30
end

function build(): {integer}
    return {10, two()}   -- {10, 20, 30}
end
```

### Indexing and reads

Arrays are indexed with square brackets and are 1-based, like Lua
sequences. The index must be an integer. An index expression of type
`float` (or `value`) is accepted and converted with a run-time check:
an integral float such as `2.0` denotes the same element as `2`, and a
non-integral one raises a run-time error. An option-typed index such as
`integer?` is also accepted: it is unwrapped with a nil check, so a `nil`
index raises a clean run-time error. An index of a
non-numeric type such as a string is a compile-time error: `types in
array indexing do not match, expected integer but found string`.

```lua
-- Titan (mod.titan)
function pick(xs: {string}, i: float): string
    return xs[i] or ""    -- float index: converted with a run-time check
end
```

```lua
-- Lua
local mod = require "mod"
print(mod.pick({"a", "b", "c"}, 2.0))        --> b
print(pcall(mod.pick, {"a", "b", "c"}, 2.5))
--> false   type error at line 3, number '2.5' has no integer representation
```

Reading `xs[i]` from a `{T}` always has type `T?` — an
[option type](option-types.md) — because the element may be absent:
out-of-bounds indices and deleted elements read as `nil`, never as an
error. What happens next depends on what you do with the value:

* **Use it where a `T` is expected** (the common case) and Titan inserts
  a run-time check that the element is actually there. Reading a missing
  element in such a context raises a run-time error of the shape
  `file:line:col: type error, expected integer but found nil`.
* **Test it** in a condition, where a missing element behaves as false.
* **Default it** with `or`, the usual Lua idiom: `xs[i] or fallback` has
  the plain type `T`.
* **Keep the option** by asking for it explicitly: option types are never
  inferred unless you opt in with a `?` on the name or an explicit `T?`
  annotation.

```lua
function reads(xs: {integer}): integer
    local a = xs[2]         -- a: integer — checked, errors if absent
    local b? = xs[5]        -- b: integer? — holds nil when absent, no error
    local c = xs[5] or -1   -- c: integer — defaulted to -1
    return c
end

function describe(xs: {integer}, i: integer): string
    if xs[i] then
        return "present"
    else
        return "absent"
    end
end
```

Indexing nests through options transparently: with `a: {{string}}`, the
expression `a[1][1]` first checks that `a[1]` is present, then indexes
it.

### Writes and deletion

Assigning to `xs[i]` stores an element, with the usual implicit
coercions applied to the value (an integer stores into a `{float}`).
Assigning `nil` *deletes* the element, exactly as in Lua:

```lua
-- Titan (mod.titan)
function delete(xs: {integer}, i: integer)
    xs[i] = nil
end
```

```lua
-- Lua
local mod = require "mod"
local xs = {1, 2, 3}
mod.delete(xs, 3)
print(#xs)   --> 2
```

### Length

`#xs` returns the length of the array as an integer:

```lua
function len(xs: {string}): integer
    return #xs
end
```

The semantics are Lua's: `#` returns a *border* of the underlying table.
For an array without holes that is its number of elements; if you have
deleted elements from the middle, which border you get is unspecified,
just as for a Lua table.

Maps have no length: `#m` on a map is a compile-time error
(`trying to take the length of a { string : integer } instead of an
array or string`). This is deliberate; when maps were added the design
note was that "the Lua meaning of `#` is pretty accidental on the Lua
objects backing maps; `#` in tables is meant for tables-as-arrays and we
have a separate type for that."

### Growth

Arrays grow as you append to them; the standard Lua idiom works and is
the intended way to build an array incrementally:

```lua
function push(xs: {integer}, v: integer)
    xs[#xs + 1] = v
end
```

A store just past the current capacity grows the array part by doubling,
so repeated appends are cheap. Any integer index is legal: writes far
beyond the current size (and non-positive indices) fall back to the
table's generic path and land in its hash part, exactly as in a Lua
table, and indices are handled at full 64-bit width — `xs[(1 << 32) + 1]`
addresses its own element and cannot clobber `xs[1]`.

## Maps

### The map type `{K: V}`

`{K: V}` is the type of maps from keys of type `K` to values of type
`V`:

```lua
local scores: {string: integer} = {}
local index: {integer: {string}} = {}   -- values can be any type
```

As with arrays, the value type is always a plain type — `{string:
integer?}` is accepted but means the same as `{string: integer}`, since
reads already produce `integer?`.

### Constructors

A map is created with a brace-enclosed list of `[key] = value` entries.
Key and value expressions are coerced to the key and value types; the
map type can be inferred from the first entry when the context gives
none:

```lua
local ages = { ["ana"] = 31, ["bia"] = 27 }          -- {string: integer}
local flags: {float: boolean} = { [2.5] = true, [3.14] = false }
```

The bracketed key syntax is mandatory, *even for string keys*. The
unbracketed named-entry form `{ x = 10 }` is the
[record constructor](records.md) syntax, and Titan decides what kind of
constructor it is looking at from the shape of the entries themselves —
bare expressions make an array, bracketed keys make a map, named entries
make a record. Using a named entry where a map is expected is a
compile-time error:

```lua
local m: {string: integer} = { x = 10 }
-- compile-time error: initializing field 'x' when expecting map
```

Keeping the named-entry form exclusively for records is what lets the
three constructor kinds be told apart syntactically.
The compiler's test suite marks the string-keyed-map case with a
`FIXME should this be allowed?`, so this restriction may yet be
revisited.

Note that an empty `{}` only becomes a map when the context expects a
map type; with no context, `{}` defaults to the *array* type
`{integer}`.

A multiple-return call in value position of a map constructor is
truncated to its first value (extra returns are dropped, without error).

### Keys

Any Titan type can be the key type **except** `nil` and option types,
which are rejected at compile time:

```lua
-- local m: {nil: integer} = {}       -- type of map key cannot be nil
-- local m: {string?: integer} = {}   -- type of map key cannot be option type
```

Everything else works — the test suite exercises every combination of
`value`, `boolean`, `integer`, `float`, `string`, an array type, a map
type, and a record type as both keys and values. Keys that are
themselves tables or records are hashed and compared by identity, as in
Lua: two distinct arrays with equal contents are two distinct keys.

Numeric keys follow Lua's normalization rule: a float key with an
integral value is the same key as the corresponding integer. In a
float-keyed map an integer key expression is implicitly coerced to
float, so both spellings reach the same entry:

```lua
function same_entry(): string
    local m: {float: string} = {}
    m[1] = "one"                  -- integer key, coerced to 1.0
    return m[1.0] or "absent"     -- returns "one": the same entry
end
```

### Reads, writes and deletion

Indexing a `{K: V}` map reads with type `V?`: a missing key yields
`nil`, never an error, and the same option-type machinery as for arrays
applies — checked unwrapping in `V` contexts, truthiness tests, `or`
defaulting. Writing stores an entry (with implicit coercion of both key
and value), and writing `nil` removes the key:

```lua
function count_words(words: {string}): {string: integer}
    local counts: {string: integer} = {}
    for i = 1, #words do
        local w = words[i]
        counts[w] = (counts[w] or 0) + 1
    end
    return counts
end

function forget(counts: {string: integer}, w: string)
    counts[w] = nil   -- removes the entry
end
```

## Arrays and maps are Lua tables

A Titan array or map *is* a Lua table. Passing one to Lua, or receiving
a table from Lua, never copies: both sides alias the same object, and
mutations made on either side are immediately visible to the other.

```lua
-- Titan (mod.titan)
function modify_map(m: {string: boolean}): {string: boolean}
    m["hello"] = true
    return m
end
```

```lua
-- Lua
local mod = require "mod"
local t = { ["world"] = false }
local t2 = mod.modify_map(t)
assert(t2 == t)            -- the same table came back, not a copy
assert(t.hello == true)    -- Titan's write is visible to Lua
assert(t.world == false)   -- Lua's contents are visible to Titan
```

Consistently with this, `==` between two arrays (or two maps) of the
same type compares identity — it is true only when both sides are the
very same table, which is Lua's equality for tables without metamethods.
Comparing containers of different types is a compile-time error, and the
ordering operators do not apply to containers at all.

Inside Titan, table accesses are always *raw*: Titan arrays and maps
have no metatables, and if Lua passes in a table that has one, its
`__index`/`__newindex` metamethods are ignored by Titan code.

### Contents are not checked at the boundary

When a table crosses from Lua into a Titan parameter of array or map
type, the boundary check verifies only that the value *is* a table — a
non-table raises a run-time error such as `expected table but found
number` (arrays and maps both report as `table` in these messages). The
*contents* are not inspected at the boundary. Instead, every element
access inside Titan carries its own typed check, so an ill-typed value
that Lua has placed in the table surfaces as a run-time error later, at
the first Titan access that touches it:

```lua
-- Titan (mod.titan)
function bump(m: {string: integer}): integer
    m["foo"] = m["foo"] + 10
    return m["foo"]
end
```

```lua
-- Lua
local mod = require "mod"
local m = { foo = 10 }
print(mod.bump(m))         --> 20
print(mod.bump(m))         --> 30
m.foo = "wat"              -- Lua breaks the typing assumption...
print(pcall(mod.bump, m))  --> false   mod.titan:<line>:<col>: type error,
                           --          expected integer but found string
```

This is a deliberate deferred-check design: the boundary check stays
constant-time regardless of the table's size, and the per-access checks
guarantee that Lua can never make Titan *misbehave* — only make it raise
a well-located error. The consequence to keep in mind when debugging is
that the error names the Titan access site, not the Lua write that
planted the bad value. See [Lua interoperability](lua-interop.md) for
the full boundary rules and [Error handling](error-handling.md) for
catching these errors with `pcall`.

## Performance model

A Lua table internally has an *array part* (a dense vector for integer
keys 1..n) and a *hash part* (for everything else). Titan's container
types exist so the compiler can target each part directly instead of
going through the interpreter's generic table access: array reads
compile to an inlined bounds-check plus a direct load from the array
part, array writes to a direct store with inlined growth, and map
accesses dispatch on the static key type to the matching specialized
hash lookup — all skipping the metamethod dispatch and stack traffic of
the generic paths. As one of the authors put it while maps were being
added: "Exploiting the type information that we have, specially when it
is such low-hanging fruit, is not premature optimization, it is one of
the points of having the types in the first place!" The practical
guidance is the same as for Lua, only more so: keep arrays dense and
1-based so they stay in the array part, and use maps when keys are not
a contiguous integer range.

*Implementation note:* the exact generated code for every operation in
this chapter — constructors, the three-tier array write, the per-key-type
map lookups — is shown in
[the codegen construct catalogue](../implementation/codegen-constructs.md),
and the GC anchoring discipline behind it in
[values and GC](../implementation/values-and-gc.md).
