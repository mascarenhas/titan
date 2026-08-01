# Garbage-collection library implementation

The user-facing contract is in the
[garbage-collection standard-library chapter](../language/standard-library-gc.md).
`titan.gc` is a flat Titan module built against the repository's pinned Lua
5.5 headers. It adds no compiler intrinsic or C shim.

## Weak-mode stack ledger

Changing a Map's weakness is an audited raw-Lua operation because a Titan Map
does not otherwise expose its metatable. `set_weak_mode` uses this ledger:

| Operation | Stack effect and obligation |
| --- | --- |
| `lua_gettop` | Save the exact entry height. |
| `lua_checkstack(L, 4)` | Reserve the maximum map, metatable, key, and value temporaries. |
| `ffi.lua_pushtvalue(map)` | Push the existing Map as a temporary root. |
| `lua_getmetatable` | Push the exact existing metatable when present; it does not invoke `__index`. |
| no-metatable branch | Construct a traced Titan Map containing `__mode`, push it, and install it with `lua_setmetatable`. |
| existing-metatable branch | Push `"__mode"` and the selected mode and call `lua_rawset`; raw assignment cannot invoke a metatable-of-metatable `__newindex`. |
| deferred `lua_settop` | Restore the exact entry height on every exit. |

The existing metatable is never copied or replaced. While it is being mutated,
the Lua stack roots it; a new metatable is also held by a traced Titan local.
`lua_setmetatable` and `lua_rawset` perform Lua's normal barriers, so the module
does not manipulate collector internals. Allocation or Lua errors follow the
generated function's longjmp boundary and its deferred stack restoration.

Shared metatables make weakness a shared policy: changing the raw `__mode`
field for one Map changes what every table using that metatable observes. This
is part of the public contract rather than an identity workaround.

This is also the sole stdlib weak-Map implementation boundary. PEG's private
compiled-pattern cache and string's private compiled-regex cache retain their
precise `{string: Pattern}` and `{string: Regex}` types for ordinary access,
then pass the same Map through a local `{value: value}` view to `gc.weak` once
at initialization. Neither module duplicates Lua stack or metatable code.

## Direct collector control

Collector operations call the public variadic `lua_gc` API directly. These
calls are stack-neutral and return only C integers, so they need no temporary
Lua roots or stack restoration. Every result passes through one validator;
Lua's `-1` result for an operation attempted during an internal stop/finalizer
becomes a Titan error.

The option mapping is direct:

| Titan operation | Lua 5.5 option |
| --- | --- |
| `pause`, `resume`, `paused` | `LUA_GCSTOP`, `LUA_GCRESTART`, `LUA_GCISRUNNING` |
| `collect`, `step` | `LUA_GCCOLLECT`, `LUA_GCSTEP` with a `size_t` argument |
| `incremental`, `generational` | `LUA_GCINC`, `LUA_GCGEN` |
| tuning accessors | `LUA_GCPARAM` with the corresponding `LUA_GCP*` integer and `-1` for query-only |

Mode-changing calls return the previous mode constant, which the public
boolean converts into “already in the requested mode.” Parameter settings are
validated in Titan before their checked conversion to C `int`; Lua 5.5's
documented range is `0..100000`.

`count` makes two stack-neutral calls. `LUA_GCCOUNT` supplies the whole
kilobytes and `LUA_GCCOUNTB` the remainder, producing
`kilobytes * 1024 + remainder` as a Titan integer. This avoids the fractional
number and rounding used by Lua's `collectgarbage("count")` presentation.
