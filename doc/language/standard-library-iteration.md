# Iteration standard library

The `titan.iteration` module provides generic Map and Array iterators:

```titan
local iteration = import "iteration"
```

Lua code loads the same installed standard-provider module with
`require "titan.iteration"`.

## Map iteration

`next` is generic in the Map's key and value types:

```titan
function next<K, V>(map: {K: V}, key: K?): (K?, V?)
```

It has Lua's `next` semantics. A nil key starts the traversal. A successful call
returns the next key and value; exhaustion returns two nil values. Both results
are options because an ordinary call can observe exhaustion directly. The key
type argument must still satisfy the ordinary [Map key
rules](arrays-maps.md#maps); generics do not admit nil or an option as a stored
key type.

Titan normally infers `K` and `V` from the concrete Map argument. The call
therefore preserves the Map's types instead of widening them to `value`:

```titan
local scores: {string: integer} = {
  ["alice"] = 10,
  ["bob"] = 20,
}

local name?, score? = iteration.next(scores, nil)
```

A call may also give the complete explicit application:

```titan
local name?, score? =
  iteration.next<string, integer>(scores, nil)
```

A control key that is neither nil nor present in the Map raises Lua's
`invalid key to 'next'` error. Traversal order is unspecified. As with Lua's
primitive, adding new keys during a traversal is not supported.

`pairs` returns the complete iterator tuple required by Titan's generic `for`:

```titan
function pairs<K, V>(map: {K: V}):
    (({K: V}, K?) -> (K?, V?), {K: V}, nil, nil)
```

The values are `(next, map, nil, nil)`: iterator, state, initial control, and no
close function. `K` and `V` are inferred from `map` in the usual call, while
`pairs<string, integer>(scores)` is the corresponding explicit application:

```titan
for name, score in iteration.pairs(scores) do
  use_score(name, score)
end
```

The Map argument infers `K = string` and `V = integer`, so the loop needs no
repeated control-variable annotations. It forces the nonnil first result into
`name`; exhaustion is decided only by that result. A false key is an ordinary
control value and does not stop the loop.

## First-class instantiation

A generic declaration is not itself a polymorphic run-time value. A complete
monomorphic function context can instantiate `next`:

```titan
local string_next:
    ({string: integer}, string?) -> (string?, integer?) = iteration.next

local name?, score? = string_next(scores, nil)
```

The resulting function is a normal first-class Titan callable. As with other
generic function values, an adjustment may allocate a fresh wrapper; its
identity is not promised to equal another instantiation.

## Array iteration, including holes

`ipairs` is generic in the Array element type:

```titan
function ipairs<T>(array: {T}):
    (({T}, integer) -> (integer?, T?), {T}, integer, nil)
```

It returns a private step function, the original Array, control value `0`, and
no close function. `T` is normally inferred from the Array, or it can be given
explicitly as in `iteration.ipairs<string>(items)`.

Iteration visits every integer from 1 through `#array`. Unlike Lua's `ipairs`,
an inner nil element does not stop traversal because the nonnil index is the
first iterator result:

```titan
local items: {string} = { "first", "middle", "third" }
items[2] = nil

for index, item? in iteration.ipairs(items) do
  -- Runs for indexes 1, 2, and 3; item is nil at index 2.
  consume(index, item)
end
```

Array length is Titan's deterministic highest-present index. Assigning nil to
the trailing position removes it and can therefore shorten the iteration;
there is no separate retained logical length.

## Erasure and delayed projection errors

The type arguments are compile-time information. `next`, `pairs`, and `ipairs`
each have one erased implementation; Lua sees their ordinary all-`value`
application. No run-time key or element type witness is attached to a Map or
Array.

Consequently the usual [Transient/Shallow generic storage
rule](generics.md#raw-writes-and-delayed-failure) applies. Lua or a generic
function can put a raw carrier value into a dependent Map value or Array element.
The write may return normally, but a later closed iterator result is checked:

```titan
local function replace<K, V>(map: {K: V}, key: K,
                             replacement: value)
  local item: V = replacement
  map[key] = item
end

local scores: {string: integer} = {}
replace<string, integer>(scores, "alice", "not an integer")

-- The precise integer? result projection raises "expected integer".
local name?, score? =
  iteration.next<string, integer>(scores, nil)
```

The same rule applies to the `T?` item returned by `ipairs<T>`. A successful
projection checks one use; it does not sanitize the aliased container, so a
later precise read checks again.
