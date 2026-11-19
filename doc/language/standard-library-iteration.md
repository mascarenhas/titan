# Iteration standard library

The `iteration` standard module provides generic iterators for Titan Maps
(`pairs`, `next`) and Arrays (`ipairs`), preserving static key, value, and
element types without widening to `value`. Titan imports it with
`local iteration = import "iteration"` (parser sugar for
`import "titan.iteration"`); Lua loads the same module with
`require "titan.iteration"`.

**Target availability:** Native & Browser (complete).

## Example

This module uses `next` to test for an empty Map in O(1), `pairs` to sum a
typed Map, and `ipairs` to traverse an Array without stopping at interior `nil`
holes:

```titan
local iteration = import "iteration"
local strings = import "string"

function is_empty<|K, V|>(map: {K: V}): boolean
  local first_key? = iteration.next(map, nil)
  return first_key == nil
end

function total_score(scores: {string: integer}): integer
  local sum = 0
  for _, score in iteration.pairs(scores) do
    sum = sum + score
  end
  return sum
end

function format_slots(slots: {string}): string
  local out = strings.writer()
  defer out:close()
  for index, label? in iteration.ipairs(slots) do
    out:write(strings.format("%d:%s ", index, label or "<empty>"))
  end
  return out:drain()
end
```

## Map iteration

```text
function next<|K, V|>(map: {K: V}, key: K?): (K?, V?)
function pairs<|K, V|>(map: {K: V}):
    (function ({K: V}, K?): (K?, V?), {K: V}, nil, nil)
```

`next(map, key?)` steps through a Map with Lua's `next` semantics:

- Pass `nil` as `key` to obtain the first `(key, value)` pair, and pass each
  returned key to advance. Exhaustion returns `(nil, nil)`.
- Passing a non-`nil` key that is absent from `map` raises
  `invalid key to 'next'`.
- Traversal order is unspecified. Inserting new keys during traversal has
  unspecified behavior; updating or deleting the current key is safe.
- `K` must satisfy Titan's [Map key rules](arrays-maps.md#maps) (`nil` and
  option types are not valid Map keys).

`pairs(map)` returns the four-slot generic-`for` tuple `(next, map, nil, nil)`.
Titan infers `K` and `V` from `map` automatically (or accepts explicit type
arguments such as `iteration.pairs<|string, integer|>(scores)`). The loop stops
only when the control key is `nil`, so a `false` boolean key is visited
normally:

```titan
local iteration = import "iteration"

function count_boolean_keys(flags: {boolean: integer}): (integer, integer)
  local count = 0
  local total = 0
  for key, amount in iteration.pairs(flags) do
    count = count + 1
    if key then total = total + amount end
  end
  return count, total
end

function first_entry(scores: {string: integer}): (string?, integer?)
  return iteration.next<|string, integer|>(scores, nil)
end
```

## Array iteration

```text
function ipairs<|T|>(array: {T}):
    (function ({T}, integer): (integer?, T?), {T}, integer, nil)
```

`ipairs(array)` returns `(step, array, 0, nil)` and visits every integer
position from `1` through `#array`. Because the first yielded value is the
non-`nil` integer index, interior `nil` holes do **not** terminate the loop
(unlike Lua's `ipairs`). Bind the second loop variable with `?` when the Array
may contain holes:

```titan
local iteration = import "iteration"

function count_holes(items: {string}): integer
  local holes = 0
  for _, item? in iteration.ipairs(items) do
    if item == nil then holes = holes + 1 end
  end
  return holes
end
```

`#array` is Titan's deterministic highest present positive index, so deleting
the trailing element (`items[#items] = nil`) shortens subsequent traversals.
`ipairs` accepts mutable `{T}` Arrays; to traverse `const { T }` or
`const? { T }` Arrays, use a numeric `for i = 1, #items do` loop.

## First-class instantiation

A monomorphic function-type annotation instantiates `iteration.next` as a
first-class callable:

```titan
local iteration = import "iteration"

function first_score(scores: {string: integer}): (string?, integer?)
  local string_next:
      function ({string: integer}, string?): (string?, integer?) =
    iteration.next
  return string_next(scores, nil)
end
```

Each generic instantiation may produce a fresh callable wrapper whose identity
is not guaranteed to match another instantiation.

## Type erasure and delayed checks

`next`, `pairs`, and `ipairs` each compile to one erased implementation; Lua
callers see their all-`value` specialization. Because a Map table—or an Array
accessed through a `{value}` view or erased generic code—can hold arbitrary Lua
values, [type erasure](generics.md#type-erasure-runtime-checks-and-lua) means
Lua code or a generic helper can store an incompatible value into a container
and succeed at the write site. The iterator then enforces the expected type
when a typed call reads that slot back:

```text
local function put_raw<|K, V|>(map: {K: V}, key: K, raw: value)
  local item: V = raw
  map[key] = item
end

local scores: {string: integer} = {}
put_raw<|string, integer|>(scores, "alice", "not an integer")

-- Raises "expected integer" when projecting the typed result:
local name?, score? = iteration.next<|string, integer|>(scores, nil)
```

The same check runs on each `T?` element yielded by `ipairs<|T|>`.
