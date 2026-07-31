# Garbage-collection standard library

The `titan.gc` module configures weak Maps and exposes explicit control of the
Lua 5.5 collector used by Titan. Import it by its qualified name:

```titan
local gc = import "titan.gc"
```

There is deliberately no compiler-level `gc` import alias. Lua code loads the
same installed standard-provider module with `require "titan.gc"`.

Collector state belongs to the complete Lua state, not to one Titan module or
Task. Pausing it, changing its mode, or changing a parameter affects all Titan
and Lua code in that state.

## Weak Maps and ephemerons

```titan
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

## Collector actions and queries

```titan
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
