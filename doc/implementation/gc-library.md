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

## Finalizer stack ledger

`finalizable<|T|>(v: T, f: function (T): ())` is the matching audited boundary for
attaching a Lua finalizer to an existing table or full userdata. The declared
scheme ties the candidate and callback together at the source boundary. Its one
code-facing body erases unconstrained `T` to `value` and `function (T): ()` to
`function (value): ()`; there is no reified type argument or specialized finalizer
body:

| Operation | Stack effect and obligation |
| --- | --- |
| `lua_gettop` | Save the exact entry height. |
| `lua_checkstack(L, 4)` | Reserve the value, metatable, key, and callback temporaries. |
| `ffi.lua_pushtvalue(v)` | Use the ordinary erased whole-slot `value` to `TValue` adjustment, then push and root the exact candidate. |
| `lua_type` | Accept only `LUA_TTABLE` or `LUA_TUSERDATA`; light userdata has its own tag and is rejected. This remains a run-time check even for a scalar application. |
| `lua_getmetatable` | Push the exact existing metatable when present. |
| no-metatable branch | Construct a traced Titan Map containing the erased Lua-callable `__gc = f` and push it. |
| existing-metatable branch | Raw-set the erased Lua-callable `__gc = f`, preserving the metatable identity and every other field. |
| `lua_setmetatable` | Install the new metatable or reinstall the exact old one, causing Lua to run its finalizer-marking path for this existing value. |
| deferred `lua_settop` | Restore the exact entry height on success or error. |

Erasure changes neither the four-slot reservation nor any operation in this
ledger. A concrete `Owner` or `{string: integer}` application uses the generic
call boundary's ordinary traced callable adjustment to present its exact
callback as the erased `function (value): ()` formal. The same existing whole-slot
adjustment supplies `ffi.lua_pushtvalue`; `titan.gc` has no generic-specific
Lua API whitelist or alternate stack path. Conversely, an `integer`
application boxes its candidate normally, reaches `lua_type`, raises there,
and still executes the deferred `lua_settop` before the error escapes.

Simply adding `__gc` to a metatable already attached to a table or userdata is
not sufficient: Lua marks a collectable object as finalizable while assigning
its metatable. Reinstalling the same metatable after the raw field write is
therefore semantic, not an identity workaround. The candidate, metatable, and
callback remain rooted on the Lua stack until that operation completes, and
the normal table/metatable barriers record every new edge.

Finalizer marking belongs to objects, while `__gc` lookup belongs to their
metatable. Preexisting peers which shared the metatable before its first
`__gc` write remain unmarked; objects assigned that metatable afterward are
marked by ordinary `lua_setmetatable`, and already-marked peers observe any
later raw replacement of `__gc`. Reinstalling the metatable repeatedly does
not add duplicate finalizer-list entries.

No C trampoline is involved. A Titan function value is already a Lua-callable
closure whose upvalues retain its module and native entry point. For a concrete
record or Map callback, the normal generic-call adjustment closure strictly
projects Lua's erased argument to that exact static parameter before calling
the concrete body; the callback therefore needs no source `value as Record`
cast. Storing the erased closure as `__gc` lets Lua invoke its ordinary
generated Lua entry with the finalized table or userdata as the sole argument.
This also keeps the owning standard-provider module reachable for as long as
the finalizer can run. Lua invokes that entry through its non-yielding
protected finalizer call with collector steps internally stopped. A callback
boundary or body error is converted to a Lua warning rather than propagated.

The metatable remains the only callback slot. Generic applications share the
one erased implementation, and values sharing a metatable still observe its
latest raw `__gc`; neither `T` nor the adjustment closure gives Lua per-value
callback dispatch. Native tests therefore exercise exact record and Map
callbacks through Lua, callback replacement on a shared metatable, and scalar
rejection with a zero stack delta.

The adjustment closure exists only when the callback's erased type differs from
the erased formal `function (value): ()`: the generic boundary compares erased
types, so a callback whose erased type is already `function (value): ()` is
exact, the argument is the caller's closure itself, and the raw `__gc` keeps
its identity. Any other callback parameter type (a record, union, Interface,
Array, Map, or scalar) allocates one fresh adjustment closure per call.
A constructor that registers a finalizer on every allocation of a frequently
created owner can use that form, strictly projecting its argument back to the
owner type inside the callback, to avoid one closure allocation per
registration and an adapter hop per finalization. `titan.thread` endpoint
wrappers do this. The gc native tests check that a `value` registration
installs the passed closure itself as `__gc`, and the thread ownership tests
check that every endpoint construction route leaves one shared `__gc` identity.

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
