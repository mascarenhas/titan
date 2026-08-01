# Iteration standard library

The `titan.iter` module provides the small, dynamically typed iterator kernel
used for generic maps and Arrays. Import it by its qualified name:

```titan
local iter = import "titan.iter"
```

There is deliberately no compiler-level `iter` import alias. Lua code loads the
same installed standard-provider module with `require "titan.iter"`.

## Map iteration

`next` has the signature:

```titan
function next(map: {value: value}, key: value): (value, value)
```

It has Lua's `next` semantics. A nil key starts the traversal. A successful call
returns the next key and value; exhaustion returns two nil values. A control key
that is neither nil nor present in the map raises Lua's `invalid key to 'next'`
error. Traversal order is unspecified. As with Lua's primitive, adding new keys
during a traversal is not supported.

Concrete Maps are consistent with the `{value: value}` view. The returned key
and item nevertheless have static type `value`, so consumers cast them or give
the generic-for declarations the desired types:

```titan
local iter = import "titan.iter"

local scores: {string: integer} = {
  alice = 10,
  bob = 20,
}

for name: string, score: integer in iter.pairs(scores) do
  use_score(name, score)
end
```

`pairs` returns the complete iterator tuple in the order required by Titan's
generic `for`:

```titan
function pairs(map: {value: value}):
    (({value: value}, value) -> (value, value),
     {value: value}, nil, nil)
```

The values are `(next, map, nil, nil)`: iterator, state, initial control, and no
close function. A false map key is an ordinary control value and does not stop
the loop; only nil does.

## Array iteration, including holes

`ipairs` returns an index iterator over an Array:

```titan
function ipairs(array: {value}):
    (({value}, integer) -> (integer?, value), {value}, integer, nil)
```

It visits every integer from 1 through `#array`. Unlike Lua's `ipairs`, an inner
nil element does not stop the traversal because the nonnil index is the first
iterator result:

```titan
local iter = import "titan.iter"
local items: {value} = { "first", nil, "third" }

for index, item in iter.ipairs(items) do
  -- Runs for indexes 1, 2, and 3; item is nil at index 2.
  consume(index, item)
end
```

Array length is Titan's deterministic highest-present index. A trailing nil
assignment removes that position and therefore can shorten the iteration;
there is no separate retained capacity or logical length.

These `{value}` and `{value: value}` functions are intentionally a temporary
dynamic kernel. They do not claim parametric result types; future generic
collection APIs can provide those without changing generic-for's four-slot
protocol.
