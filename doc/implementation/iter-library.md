# Iteration-library implementation

The user-facing contract is in the
[iteration standard-library chapter](../language/standard-library-iter.md).
`titan.iter` is a flat Titan source module. It needs no compiler syntax,
type-relation, or code-generator changes: callers use the qualified
`import "titan.iter"`, and `pairs` returns the generic-for protocol already
implemented by the language.

## `next` as an audited Lua-stack operation

Ordinary Titan has no primitive for traversing a Map's hash part. The module
therefore implements `next` through the same trusted, module-private Lua C API
boundary used by the PEG and string libraries. Its stack ledger is:

| Operation | Stack effect and obligation |
| --- | --- |
| `lua_gettop` | Save the exact entry height. |
| `lua_checkstack(L, 3)` | Reserve the map, control key, and returned item slot before pushing. |
| `ffi.lua_pushtvalue(map)` | Push and root the existing Map. |
| `ffi.lua_pushtvalue(key)` | Push and root the current control key, including nil. |
| `lua_next(L, -2)` | Pop the control key; on success push the next key and item, or on exhaustion push nothing. It can raise for an invalid key. |
| `ffi.lua_totvalue` | Copy each successful result into a traced Titan `value` before cleanup. |
| deferred `lua_settop` | Restore the saved height on success, exhaustion, return, or a Lua error. |

The copied `value` locals are GC-visible after the temporary stack roots are
removed. No pointer into a table or stack slot survives the operation. An error
from `lua_next` crosses the generated Titan error boundary; the enclosing
`defer` is the single cleanup path rather than a guessed sequence of pops.

## Iterator tuple shapes

`pairs` returns `(next, map, nil, nil)`. The exact first-class type of `next` is
`({value: value}, value) -> (value, value)`, so generic-for calls it with the
state Map and previous key. A nil first result stops the loop; false remains a
valid key.

Array iteration needs no raw API. Its private step function increments the
integer control value, compares it with the Array's deterministic `#` result,
and returns `(index, array[index])`. The index is deliberately first, so an
inner nil item occupies an ordinary iteration rather than signaling
exhaustion. Both helpers return nil close slots because they own no resource.

The dynamic container views are intentional placeholders for future
parametric-polymorphic iterators. They preserve container identity and defer
element checks to the consumer without adding a special compiler relation.
