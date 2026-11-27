# Garbage-collection standard library

`titan.gc` configures weak Maps and ephemerons, attaches reachability
finalizers to tables and full userdata, keeps GC-managed values reachable
through explicit call points, and controls Lua 5.5's garbage collector.
Collector state belongs to the entire Lua state, so pausing, switching modes,
or tuning parameters affects all Titan and Lua code in that state.

- **Import:** `local gc = import "gc"` (Titan) · `require "titan.gc"` (Lua)
- **Targets:** Native & Browser (complete)

## Quick examples

Create a weak-value cache whose unreferenced entries disappear on collection:

```titan
local gc = import "gc"
local io = import "io"

record Entry
  const label: string
end

local function store_transient(cache: {string: Entry}, key: string, label: string)
  cache[key] = Entry(label)
end

function main(_args: {string}): integer
  local cache: {string: Entry} = {}
  gc.weak(cache)

  store_transient(cache, "ephemeral", "temp")
  local pinned = Entry("kept")
  cache["pinned"] = pinned

  gc.collect()
  gc.collect()
  io.print(cache["ephemeral"] == nil, cache["pinned"] ~= nil) -- true	true
  return 0
end
```

Attach typed finalizers to both a Titan record (Lua full userdata) and a Map
(Lua table):

```titan
local gc = import "gc"
local io = import "io"

local released_total = 0

record Lease
  const id: integer
end

local function release_lease(lease: Lease)
  released_total = released_total + lease.id
end

local function release_meta(meta: {string: integer})
  released_total = released_total + (meta["weight"] or 0)
end

local function allocate_transient()
  local lease = Lease(10)
  gc.finalizable(lease, release_lease)
  local meta: {string: integer} = { ["weight"] = 5 }
  gc.finalizable(meta, release_meta)
end

function main(_args: {string}): integer
  allocate_transient()
  gc.collect()
  gc.collect()
  io.print(released_total) -- 15
  return 0
end
```

## Weak Maps and ephemerons

```text
function weak(map: {value: value})
function ephemeron(map: {value: value})
```

`weak` sets `__mode` to `"v"` (weak values); `ephemeron` sets `__mode` to `"k"`
(weak keys with Lua ephemeron semantics). Both mutate the map's metatable in
place and return no values.

If `map` has no metatable, one is created; if it already has a metatable, only
its raw `__mode` field changes and all other fields stay intact (so other Maps
sharing that metatable observe the new mode too). Weakness applies on
subsequent collections and affects only collectable objects—numbers and strings
are not collected as weak keys.

## Finalizers

```text
function finalizable<|T|>(v: T, f: function(T))
```

`finalizable` marks `v` for Lua `__gc` finalization and installs `f` on its
metatable. Type parameter `T` checks `f`'s parameter statically against `v`,
so record and Map finalizers read their fields or entries directly without
casting from `value`.

At run time, `v` must be a Lua table (Map) or full userdata (record, union,
Interface, Array, or owned foreign storage); passing `nil`, a scalar, function,
thread, or light userdata raises a runtime error. Callback return values are
discarded. Finalization follows Lua's GC schedule: it is neither prompt nor
deterministic, and a finalizer may resurrect `v`.

Unless `f` already has type `function(value)`, Titan's callable adjustment
allocates a wrapper closure on each call. For frequently allocated types, use
`finalizable<|value|>` with a reusable `function(value)` callback and project
inside it to avoid allocating a closure per object:

```titan
local gc = import "gc"

record Handle
  released: boolean
end

local function finish_handle(candidate: value)
  local handle: Handle = candidate
  handle.released = true
end

function new_handle(): Handle
  local handle = Handle(false)
  gc.finalizable<|value|>(handle, finish_handle)
  return handle
end
```

### Shared metatables and finalizer restrictions

If `v` has no metatable, `finalizable` creates one; otherwise it updates raw
`__gc` (bypassing `__metatable` and metatable `__newindex`) and reinstalls the
metatable so Lua marks `v`. Because `__gc` lives on the metatable:

- Values sharing a metatable share its latest `__gc` callback; calling
  `finalizable` again on one value replaces the callback for all marked peers.
- Keep per-instance state on the finalized record or table, and make finalizers
  idempotent (clearing owned pointers or flags before releasing resources).
- Use explicit `close` with `defer` when release must be prompt or when cleanup
  errors must propagate.

Inside a running finalizer:

- Collector actions in `titan.gc` raise
  `garbage collector operation is unavailable`.
- Uncaught errors become Lua warnings rather than propagating to the allocating
  code.
- Coroutine switches are forbidden: `coroutine.yield`, `Coroutine:resume`,
  `Coroutine:error`, and `async` waits raise, and `coroutine.is_yieldable`
  returns `false`.
- While a Lua state is closing, new `finalizable` calls are ignored. These same
  restrictions apply to `defer` cleanup of abandoned coroutines (see
  [abandoned coroutines](coroutines.md#abandoned-coroutines)).

## Keeping values reachable

```text
function keep_alive<|T|>(v: T)
```

`keep_alive` ensures that `v` remains reachable for Lua's garbage collector at
least until the call point (modeled on Go's `runtime.KeepAlive`), and returns
no values. Use it when native code, a raw pointer, or a reentrant callback
relies on a GC-managed owner staying live past the last ordinary read of its
Titan binding:

```titan
local gc = import "gc"

record Buffer
  const label: string
end

record Request
  buffer: Buffer?
end

function finish_request(req: Request, notify: function(Request))
  const retained? = req.buffer
  req.buffer = nil
  notify(req)
  gc.keep_alive(retained)
end
```

Direct calls to `gc.keep_alive` lower as a compiler intrinsic with no C
function call and no `value` boxing, while evaluating all arguments
(positional, named, or surplus) once in written order and preserving ordinary
unconstrained generic ingress. Using `gc.keep_alive` as a first-class function
value or calling `require("titan.gc").keep_alive` from Lua invokes the exported
entry and returns zero values.

Type parameter `T` obeys ordinary generic type admission on both direct and
first-class uses: Titan values, options, and `owned` C storage are accepted,
while borrowed raw C pointers, fixed C arrays, C structs or unions, C function
pointers, and `foreign void` are rejected at compile time. Because `keep_alive`
expects a value argument and returns no values, passing a zero-result call
expression or using its result as a value is a compile-time error, as with any
Titan call.

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

- `pause()` and `resume()` stop and restart automatic collection; `paused()`
  reports whether collection is paused without side effects. Pair `gc.pause()`
  with `defer gc.resume()` unless restoring an earlier paused state.
- `collect()` runs a full collection cycle.
- `step(size)` runs one collector step (`size` defaults to `0` and must be
  non-negative), returning `true` when an incremental cycle or generational
  major collection finishes.
- `incremental()` and `generational()` switch collector modes, returning `true`
  if the collector was already in that mode.
- `count()` returns Lua's live heap memory in bytes as an exact `integer`.

## Collector parameters

These six accessors read or update Lua 5.5's collector tuning parameters:

| Function | Parameter |
| --- | --- |
| `minormul(setting: integer?): integer` | Generational minor multiplier |
| `majorminor(setting: integer?): integer` | Generational major-to-minor threshold |
| `minormajor(setting: integer?): integer` | Generational minor-to-major threshold |
| `pause_percent(setting: integer?): integer` | Incremental pause percentage |
| `stepmul(setting: integer?): integer` | Incremental step multiplier |
| `stepsize(setting: integer?): integer` | Incremental step size |

Omitting `setting` queries the parameter; passing an integer in `0..100000`
updates it. Every call returns the prior setting (Lua stores parameters in a
compressed form, so a later read need not match the exact supplied integer).
Calling any collector-control function from inside a finalizer raises.
