# Interfaces

An Interface is a nominal, type-only contract consisting of read-only fields and method signatures. A record—or a union, for a method-only Interface—satisfies an Interface structurally at any conversion site without declaring an `implements` clause. When Titan converts a concrete value to an Interface, it builds a fresh wrapper whose methods dispatch to that concrete value and whose fields hold shallow snapshots taken at conversion time.

```titan
local io = import "io"
local strings = import "string"

record CountingWriter
    const label: string
    bytes: integer
end

function CountingWriter:write(data: string)
    self.bytes = self.bytes + #data
end

function copy_all(reader: io.Reader, writer: io.Writer)
    for chunk in reader:read do
        writer:write(chunk)
    end
end

function count_copied(text: string): integer
    local src = strings.reader(text)
    local dst = CountingWriter("demo", 0)
    copy_all(src, dst) -- wraps src as io.Reader and dst as io.Writer
    return dst.bytes
end
```

`CountingWriter` never mentions `io.Writer`, yet `copy_all(src, dst)` accepts it directly because `CountingWriter` defines a compatible `write(data: string)` method.

## Declaring an Interface

Interface declarations appear only at module top level and must contain at least one member:

```titan
interface NamedStream
    name: string
    tag: string?
    function write(data: string): integer
    function write_many(prefix: string, ...: string): (integer, ...: string)
    function close()
end
```

Declaration rules:

- Neither an Interface nor its members may be `local`.
- Fields have the form `name: T` (use `name: T?` for an optional field) and are implicitly read-only (`const`).
- Methods are bodyless signatures (`function name(params...): returns`) with no receiver colon and no `end`. They support fixed parameters, variadic inputs (`...: T`), multiple results, and flexible return tails (`(...: T)`).
- Fields and methods share one namespace: duplicate names and field/method collisions are compile-time errors.
- Static functions, constructors, and default method bodies are not Interface members.

### Nominal and type-only

An Interface lives solely in the module's type namespace. It is visible throughout its module regardless of source order, and importers refer to it through their import alias (`io.Reader`). Because an Interface is type-only, it is not a value—`io.Reader` cannot appear in an expression, and Lua does not see a `Reader` field on `require "titan.io"`.

Every Interface declaration has its own nominal identity (`module.InterfaceName`). Two separate Interfaces with identical members are unrelated types, and there is no Interface inheritance:

```text
interface LeftReader
    function read(): string?
end

interface RightReader
    function read(): string?
end

function bad(left: LeftReader): RightReader
    return left -- compile error: distinct nominal Interfaces
end
```

A transparent `type` alias (`type Input = io.Reader`) refers to the same nominal Interface and creates no new identity.

## Structural satisfaction at conversion sites

At every statically target-typed sink expecting Interface `I`—declarations, assignments, call arguments, returns, record fields, union payloads, container elements, module-variable initializers, and generic-`for` bindings—Titan checks every member of `I` in declaration order:

1. **Fields (records only):** For each Interface field `name: T`, the concrete record must have a visible, same-name `const` field whose type converts automatically to `T`. A mutable record field cannot satisfy a read-only Interface field, and unions cannot satisfy field-bearing Interfaces.
2. **Methods (records and unions):** For each Interface method, the concrete type must have a visible, same-name instance method whose self-removed signature fits the Interface method under directional callable adjustment ([First-Class Functions and Closures](closures.md)). Record/union static functions and variant constructors do not count.

Extra concrete fields and methods are ignored. Member kinds must match: a function-typed field cannot satisfy a method, and a method cannot satisfy a field.

Satisfaction checks visibility **at the conversion site**. A `local const` field or `local` method can satisfy an Interface inside its defining module (or an explicit `.titan` source import), while an ordinary importer that cannot see that private member is rejected.

### Field snapshots

When Titan converts a record to a field-bearing Interface, it reads and adjusts each required field once in declaration order and stores those values in the wrapper:

```titan
interface Labelled
    label: string
end

record TaskItem
    const label: string
    notes: {string}
end

function view_label(item: TaskItem): string
    local view: Labelled = item
    return view.label
end
```

Reads through an Interface observe the wrapper's snapshot, and all writes to an Interface wrapper are rejected in both Titan and Lua. Snapshotting is shallow: if a `const` record field holds a mutable Map, Array, or record, mutations to that referenced object remain visible through the snapshot.

### Parameter names and method adjustment

Concrete parameter names do not affect satisfaction. Named calls through an Interface always use the Interface declaration's parameter names:

```titan
interface PairConsumer
    function put(x: integer, y: integer)
end

record Swapped
end

function Swapped:put(y: integer, x: integer)
end

function send(swapped: Swapped)
    local consumer: PairConsumer = swapped
    consumer:put { x = 2, y = 3 } -- passes 2 as first arg (y), 3 as second arg (x)
end
```

Concrete methods may differ from the Interface signature wherever Titan's directional callable adjustment allows—for instance, ignoring trailing parameters promised by the Interface, returning fewer results when the Interface's missing result accepts `nil` (such as `value` or `T?`), or returning fixed results into a compatible flexible return tail:

```titan
interface Logger
    function log(level: integer, text: string): value
end

record Silent
end

function Silent:log()
end

function use_silent(silent: Silent): value
    local logger: Logger = silent
    return logger:log(1, "ignored") -- evaluates arguments, returns nil
end
```

Scalar coercions (numeric, Option, or Interface conversions) do not lift through method signatures. If an Interface method returns `Cloneable`, a concrete method declared as `function Node:clone(): Node` does not satisfy it; declare `function Node:clone(): Cloneable` so the `return` statement performs the `Node -> Cloneable` conversion directly.

## Conversion is not subtyping

Converting `R` to `I` is a single outer wrapper-construction operation, not a subtyping relation:

| Source | Target | Behavior |
| --- | --- | --- |
| `I` | same `I` | Identity; no allocation |
| `I` | distinct `J` | Compile-time error |
| satisfying `R` | `I` | Constructs a fresh `I` wrapper and snapshots fields |
| `I` | `value` | Boxes the existing wrapper |
| `value` | `I` | Exact `I` wrapper, or witnessed bare userdata (see below) |
| `I` | concrete `R` | Explicit `as R` downcast only |

Because conversion does not lift through containers or function types, `{R}` is not `{I}` and `function (): (R)` is not `function (): (I)`. Build `{I}` at element sinks instead:

```text
-- Assuming record Buf satisfies interface Reader:
function bad(bufs: {Buf})
    local readers: {Reader} = bufs -- compile error: no container lifting
end

function good(buf: Buf): {Reader}
    return { buf }                 -- element sink wraps buf into Reader
end
```

### Wrapper identity and Map keys

Every evaluated `R -> I` conversion constructs a **fresh** wrapper. Wrappers are not cached per concrete object, and Interface equality (`==`) compares wrapper identity:

```titan
interface Counter
    function value_of(): integer
end

record Step
    n: integer
end

function Step:value_of(): integer
    return self.n
end

function check_identities(step: Step): (boolean, boolean, boolean)
    local a: Counter = step
    local b: Counter = step
    local c = a
    return a ~= b, a == c, (a as Step) == step -- true, true, true
end
```

Comparing an Interface directly with a concrete type (`a == step`) or with a different Interface is a compile-time error.

When an Interface is used as a Map key, store the wrapper in a variable and reuse that same wrapper for insertion and lookup—otherwise each lookup wraps the concrete value anew and misses:

```titan
interface Keyed
    function id(): integer
end

record Item
    code: integer
end

function Item:id(): integer
    return self.code
end

function store_and_find(cache: {Keyed: string}, item: Item): string?
    local key: Keyed = item
    cache[key] = "present"
    return cache[key] -- finds "present" using the same wrapper identity
end
```

## Calls, bound methods, and Options

Calling a method on an Interface dispatches through the wrapper using the Interface's signature and parameter names. Naming a method without calling it (`counter:add`) yields a bound function value with `self` captured as the wrapper; once bound, call it positionally.

Optional concrete values and optional Interfaces follow explicit conversion rules:

| Source | Target | Behavior |
| --- | --- | --- |
| satisfying `R` | `I?` | Wraps `R` as a present `I` |
| satisfying `R?` | `I` | Forces non-nil (raises on `nil`), then wraps |
| satisfying `R?` | `I?` | Propagates `nil`; wraps a present `R` |
| `I` / `I?` | `I?` / `I` | Standard Option introduction and checked unwrap |
| `value` | `I?` | Propagates `nil`; present values follow dynamic `I` rules |

Calling a method or reading a field on `I?` automatically unwraps the option and raises if it is `nil`.

## Testing and downcasting (`is` and `as`)

Concrete-to-Interface casts and Interface-to-concrete downcasts are explicit:

- **Concrete to Interface:** If `R` statically satisfies `I`, `r as I` constructs a fresh wrapper, while `r is I` evaluates `r` once and returns `true` without allocating. If `R` does not satisfy `I`, both are compile-time errors.
- **Interface to concrete:** For any visible record or union `R`, `i is R` tests whether the wrapped object has exact nominal type `R`, and `i as R` returns that original concrete reference (raising on mismatch). The same operations work on `I?`: `i is R` returns `false` on `nil`, and `i as R` raises on `nil`.
- **No cross-Interface cast:** `i as J` for a distinct Interface `J` is a compile-time error; recover the concrete type first if you need to re-wrap it as another Interface.

```titan
local io = import "io"
local strings = import "string"

function try_drain(writer: io.Writer): string?
    if writer is strings.StringWriter then
        local buf = writer as strings.StringWriter
        return buf:drain()
    end
    return nil
end
```

Written casts do not combine Option adaptation with Interface conversion: `r_opt as I`, `r as I?`, and `i as R?` are rejected—use an annotated local (`local view: I? = r_opt`) or an `if` guard instead.

## Separate compilation, `value`, and Lua

A module that accepts an Interface only needs to import the module declaring that Interface—never the concrete implementation's module. For example, a formatting library can import `io` and accept `io.Writer`, while an application passes its own record to that library. Each wrapper retains the concrete object, its field snapshots, and its defining module context, so calls dispatch cleanly across independently compiled modules, shared libraries, and static archives.

### Dynamic `value` and Lua boundaries

Boxing an Interface into `value` preserves the wrapper. When a `value` or Lua argument enters a sink expecting Interface `I` (an implicit `value -> I` projection, an explicit `v as I`, a typed Array/Map element read, or a Lua call to a Titan function taking `I`), Titan accepts two cases:

1. an existing `I` wrapper (returned as-is); or
2. a bare concrete record or union instance, **provided some initialized module in the current Lua state contains a compiled static `R -> I` conversion (not merely `r is I`)** (even if that source branch never ran). In that case, Titan constructs a fresh `I` wrapper for the bare instance.

Titan does not scan methods dynamically at run time. If no loaded module has ever compiled an `R -> I` conversion, passing a bare `R` through `value` or Lua where `I` is expected raises a runtime type error. `v is I` checks whether `v` is an existing `I` wrapper or a witnessed concrete value without allocating a wrapper.

```titan
interface Sink
    function put(n: integer)
end

record Bucket
    total: integer
end

function Bucket:put(n: integer)
    self.total = self.total + n
end

function wrap_bucket(b: Bucket): Sink
    return b -- compiled R -> I conversion witnesses Bucket -> Sink at module init
end

function send_dynamic(raw: value, n: integer): boolean
    if raw is Sink then
        local sink: Sink = raw
        sink:put(n)
        return true
    end
    return false
end
```

From Lua, an Interface wrapper is userdata with a protected metatable exposing its read-only fields and public methods via colon calls (`sink:put(1)`). Every field write from Lua fails. When passing a bare Titan record from Lua to a function expecting `Sink`, the exact-or-witnessed rule applies and wraps it automatically once the witness module is loaded; retain a returned wrapper when stable identity matters.
