# Garbage-collection standard library

The `titan.gc` module configures weak Maps, attaches reachability-owned
finalizers to tables and full userdata, and exposes explicit control of the
Lua 5.5 collector used by Titan:

```titan
local gc = import "gc"
```

Lua code loads the same installed standard-provider module with `require "titan.gc"`.

Collector state belongs to the complete Lua state, not to one Titan module or
Task. Pausing it, changing its mode, or changing a parameter affects all Titan
and Lua code in that state.

## Weak Maps and ephemerons

```text
function weak(map: {value: value})
function ephemeron(map: {value: value})
```

`weak` sets `__mode` to `"v"`, making the map's values weak. `ephemeron` sets it
to `"k"`, making the map's keys weak and giving the table Lua's ephemeron
semantics. Both functions mutate the map in place and return no values.

When the map has no metatable, the function creates one. When it already has a
metatable, the exact metatable and all its other fields are preserved; only its
raw `__mode` field changes. Consequently, if several maps share that metatable,
they all observe the new mode. The mode takes effect on a later collection.
Only collectable objects can disappear through weakness; numbers and strings
used as weak keys are not made collectable by this setting.

## Finalizers

```text
function finalizable<|T|>(v: T, f: function (T): ()): ()
```

`finalizable` statically pairs the candidate with a callback over its exact
type. A record finalizer can therefore read its record fields directly, and a
Map finalizer retains its exact key and value types instead of receiving
`value` and casting it back:

```titan
local record Owner
  released: boolean
end

local function finish_owner(owner: Owner): ()
  owner.released = true
end

local function finish_cache(cache: {string: integer}): ()
  cache["closed"] = 1
end

local function configure(owner: Owner, cache: {string: integer})
  gc.finalizable<|Owner|>(owner, finish_owner)
  gc.finalizable<|{string: integer}|>(cache, finish_cache)
end
```

The callback is checked against the selected `T` by Titan's ordinary callable
rules; for example, a `function (DifferentOwner): ()` callback is rejected for
`finalizable<|Owner|>`. `T` is not a static collectability constraint, however.
An application such as `finalizable<|integer|>(17, integer_callback)` typechecks
and then raises the established run-time error. The value must still be a table
or full userdata; passing nil, a scalar, a function, a thread, or light
userdata raises. The Lua stack is restored on that error as well as on success.

At run time `T` is erased. The installed `__gc` value is the ordinary
Lua-callable erased callback, and Lua supplies the finalized object as its sole
argument. The concrete callback consequently sees its exact static parameter
type without a source `value as T` cast. Callback results are discarded.
Finalization follows Lua's ordinary garbage-collection rules: it is not prompt
or deterministic, and a callback may resurrect its value.

Unless the callback's parameter type is exactly `value`, Titan's ordinary
callable adjustment wraps it in a fresh closure on every `finalizable` call, so
the installed `__gc` is not the function that was passed. A callback whose type
is already `function (value): ()`, registered through `finalizable<|value|>`,
is installed unchanged. For an owner that is created often, use that form and
recover the owner type inside the callback (for example with
`local owner: Owner = candidate`) to avoid one closure allocation per
registration:

```titan
local gc = import "gc"

local record Handle
  released: boolean
end

local function finish_handle(candidate: value)
  local handle: Handle = candidate
  handle.released = true
end

local function new_handle(): Handle
  local handle = Handle(false)
  gc.finalizable<|value|>(handle, finish_handle)
  return handle
end
```

When `v` has no metatable, `finalizable` creates and installs one. When a
metatable already exists, the exact table and all fields other than raw
`__gc` are preserved; `finalizable` replaces that `__gc` field and reinstalls
the same metatable so Lua marks the existing value for finalization. This
bypasses both `__metatable` protection and a metatable-of-metatable
`__newindex` callback.

A shared metatable also shares its current raw `__gc` callback. Generic typing
does not record `T` on the value or create a per-application metatable. Merely
adding the field does not mark values which already had the metatable;
reinstalling it is why the value passed to `finalizable` becomes marked. A
later value which is assigned the now-finalizing metatable is marked
automatically. Every marked value looks up the metatable's current erased
callback when finalization runs, so replacing the callback also affects marked
peers and a repeated `finalizable` call on one value does not install an
independent callback.

The metatable owns that callback, not a separate per-value slot. Use one exact
callback type for values which share a metatable, and keep per-value native
state in the userdata or table passed to it. Deliberately sharing one metatable
across incompatible values also shares the latest callable adjustment; an
ordinary boundary check may then reject a peer during finalization. A finalizer
should be idempotent: clear its owned pointer or state before releasing the
underlying resource so a partially completed cleanup cannot free it twice.

Lua finalizers cannot yield or run the garbage collector. An error from the
callback produces a Lua warning and is not propagated to the code which
triggered collection. Keep finalizers to the minimum required to release their
resource; use explicit operations such as `close` when cleanup must be prompt
or its failure must be handled directly.

## Collector actions and queries

```text
function pause()
function resume()
function paused(): boolean
function collect()
function step(size: integer?): boolean
function incremental(): boolean
function generational(): boolean
function count(): integer
```

`pause` stops automatic collection and `resume` restarts it. `paused` is a
side-effect-free query and returns the opposite of Lua's collector-running
state. Code that pauses collection should use `defer gc.resume()` unless it is
deliberately restoring a previously paused state.

`collect` performs a complete cycle. `step` performs one collector step; an
omitted size is zero, and an explicit size must be nonnegative. It returns true
when an incremental cycle or a generational major collection finishes.

`incremental` and `generational` switch modes. Each returns true exactly when
the collector was already in the requested mode before the call. Code which
temporarily changes the mode can therefore remember and restore the previous
one.

`count` returns Lua's current memory use in bytes as an integer. It combines
Lua's kilobyte count and byte remainder without a floating-point round trip.
Allocations by surrounding code can naturally change the value immediately
after the query.

## Collector parameters

The six accessors correspond to Lua 5.5's collector parameters:

| Function | Parameter |
| --- | --- |
| `minormul(setting: integer?): integer` | generational minor multiplier |
| `majorminor(setting: integer?): integer` | generational major-to-minor threshold |
| `minormajor(setting: integer?): integer` | generational minor-to-major threshold |
| `pause_percent(setting: integer?): integer` | incremental pause percentage |
| `stepmul(setting: integer?): integer` | incremental step multiplier |
| `stepsize(setting: integer?): integer` | incremental step size |

Omitting `setting` only queries the parameter. Supplying a value in
`0..100000` changes it. Every call returns the previous value. Lua stores these
parameters in a compressed representation, so a later query need not reproduce
an arbitrary supplied value exactly. The `pause_percent` name keeps this tuning
parameter distinct from the zero-argument `pause()` collector action.

Lua forbids collector-control operations from inside a finalizer. If the C API
reports such an unavailable operation, `titan.gc` raises instead of fabricating
a result.
