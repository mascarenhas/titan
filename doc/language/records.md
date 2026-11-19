# Records and Methods

A record is a nominal, fixed-shape structure with typed fields and methods. Because the compiler knows the layout of every record, field access is a direct slot read or write rather than a hash lookup, and method calls dispatch directly to their target functions. Records are reference values with their own identity, and they cross the Lua boundary as userdata rather than tables.

```titan
record Point
    const id: integer
    x: float
    y: float
end

function Point:move(dx: float, dy: float)
    self.x = self.x + dx
    self.y = self.y + dy
end

function Point.origin(id: integer): Point
    return Point(id, 0.0, 0.0)
end

function shift_origin(): Point
    local p = Point.origin(1)
    p:move(3.0, 4.0)
    return p
end
```

## Declaring a record

Record declarations appear only at module top level. Each field has the form `[local] [const] name: type`, separated by newlines or semicolons:

```titan
record Node
    const key: string
    count: integer
    next: Node?
end
```

Put optionality on the field type (`next: Node?`), not on the field name. Declaring the same field twice is a compile-time error. An empty record (`record Token end`) is legal and can be constructed with `Token()`, useful as a distinct nominal marker.

Exported records belong to the module's public interface. A `local record` is private to the defining module (and explicit `.titan` source imports) and cannot appear anywhere in the module's public type surface—exported functions, public methods, exported variables, public type aliases, or public record fields.

Field, method, and record-function names accept any ASCII identifier, including reserved words such as `end` or `type` (see [Appendix C: Grammar Reference](grammar.md)).

Records may be recursive or mutually recursive, and declarations inside a module are visible regardless of source order. A method, record function, or module variable may therefore appear before the `record` declaration it refers to:

```titan
origin: Point = Point(0.0, 0.0)

function Point:is_origin(): boolean
    return self.x == 0.0 and self.y == 0.0
end

record Point
    x: float
    y: float
end
```

Field order inside the `record` declaration still determines the parameter order of the default constructor.

Record fields may hold ordinary Titan values, foreign scalars and pointers, and eligible fixed C structs, unions, and arrays; see [Calling C](ffi.md) for native C storage in records.

### Nominal identity

Records are typed nominally by their fully qualified declaration name (`module.RecordName`). Two distinct declarations with identical fields are unrelated types:

```text
record Celsius
    degrees: float
end

record Fahrenheit
    degrees: float
end

function freeze(c: Celsius): Fahrenheit
    local t: Fahrenheit = c -- compile error: expected Fahrenheit, found Celsius
    return t
end
```

Nominal identity is preserved at run time across modules and across the Lua boundary. Gradual consistency does not descend into record fields: a record with `value` fields is not interchangeable with a different record whose fields have concrete types.

## Creating records

### Calling a record

Calling a record name invokes its static `new` function. Positional calls, named calls, and single-string calls are shorthand for the corresponding calls to `Record.new`:

```titan
record Point
    x: float
    y: float
end

record Label
    text: string
end

function make_examples(): (Point, Point, Label)
    local a = Point(2.0, 3.0)               -- Point.new(2.0, 3.0)
    local b = Point { y = 4.0, x = 1.0 }    -- Point.new { y = 4.0, x = 1.0 }
    local c = Label "ready"                 -- Label.new "ready"
    return a, b, c
end
```

Prefer this shorthand when constructing records; it works for imported records and type aliases as well. Use `Point.new` explicitly when taking the constructor as a first-class function value, or when supplying member-local generic arguments on an overridden constructor. A bare record name (`Point`) is not a value.

For a generic record, explicit owner type arguments attach to the record name: `Box<|integer|>(item)` selects `Box<|integer|>.new(item)`. If a custom `new` also declares its own generic parameters and explicit arguments are needed, write `Box<|integer|>.new<|string|>(item)` (see [Generics](generics.md)).

Unless you declare a custom `new`, the compiler synthesizes a static function `Record.new` whose parameters match the record's fields in declaration order. Calling it follows ordinary Titan call adjustment ([Functions, Arguments, and Results](functions.md)):

- omitted arguments receive `nil` and are checked against the field type;
- surplus positional arguments are evaluated left-to-right and discarded;
- each argument undergoes normal assignment conversion (so `Point(2, 3)` converts `integer` arguments to `float`); and
- named calls (`Point { y = 4.0, x = 1.0 }`) evaluate explicit expressions in written order and nil-fill omitted fields.

The synthesized `new` is automatically `local` for a `local record` and for any exported record that has at least one `local` field, preventing outside callers from supplying private field values directly.

### Overriding `new`

Declare a record function named `new` to replace the synthesized constructor with custom validation, defaults, or private-field initialization:

```titan
record Counter
    local amount: integer
end

function Counter.new(initial: integer?): Counter
    local amount = initial or 0
    if amount < 0 then
        raise "negative initial count"
    end
    return { amount = amount }
end

function Counter:current(): integer
    return self.amount
end

function start_counter(): Counter
    return Counter(10)
end
```

An overridden `new` is an ordinary record function:

- It may appear before or after the `record` declaration (or in another file of a folder module).
- It chooses its own parameter list, parameter names, generic parameters, variadic tail, and return types. It may even return multiple values or omit the record altogether, as when a constructor returns `(Record?, string?)` or parsed results.
- It chooses its own visibility: a public `Counter.new` may initialize `local` fields, and a `local` override restricts construction even when all fields are public.

Because the override completely replaces the synthesized constructor, calling `Counter(...)` or `Counter.new(...)` inside `Counter.new` recurses. Allocate the raw record with a context-typed constructor expression (`{ amount = amount }`) inside the defining module. Once a record overrides `new`, raw `{ ... }` construction is restricted to the defining module—importers, including explicit `.titan` source imports, must construct instances through `new` even when all fields are public.

### Constructor expressions

Where the surrounding context expects a specific record type, a brace expression `{ field = value, ... }` allocates the record directly:

```titan
record Config
    label: string?
    enabled: boolean
    retries: integer
end

function default_config(): Config
    local cfg: Config = { retries = 3 } -- label is nil, enabled is false
    return cfg
end

function assign_config(): Config
    local cfg = default_config()
    cfg = { label = "fast", enabled = true, retries = 1 }
    return cfg
end
```

Record-expecting contexts include annotated declarations and module variables, assignments to record-typed targets, arguments to record-typed parameters, `return` statements, nested record fields, and elements of typed container constructors. Without such a context, `{ field = value }` is a compile-time error.

Constructor expressions check every field at compile time:

- Unknown field names are rejected, and entries must be named rather than positional (`{ 1.0, 2.0 }` is invalid for a record).
- Both mutable and `const` fields are initialized during construction.
- An omitted field receives `nil` only when `nil` converts to its type (such as `T?`, `value`, `boolean` converting to `false`, or a nullable C pointer); otherwise omission is a compile-time error.
- Each value undergoes ordinary assignment conversion to its field type.
- If a field name is written more than once in a constructor expression, every expression evaluates in source order and the last one wins. (Named *calls* reject duplicate argument names.)

Raw constructor expressions require visibility of every field. Outside the defining module, a record with `local` fields or a custom `new` cannot be built with `{ ... }`.

### Records in module variables

A module variable may be initialized with a raw `{ ... }` constructor or a call to the default synthesized `new`:

```titan
record Bounds
    low: integer
    high: integer
end

default_bounds: Bounds = Bounds(0, 100)
wide_bounds: Bounds = { low = -100, high = 100 }
```

An own-module overridden `new` is a module function and cannot run in a module-variable initializer; put that initialization in the module's root `do ... end` block instead. An imported custom `new` may run in a module-variable initializer subject to the initializer dependency rules in [Modules and Program Structure](modules.md).

## Fields: mutable, `const`, and `local`

Fields are read and written with dot notation. Assignments copy the record reference, never its contents, so mutations through one variable are visible through every alias:

```titan
record Inner
    count: integer
end

record Outer
    inner: Inner
    on_bump: function (integer): ()
end

function bump(box: Outer)
    box.inner.count = box.inner.count + 1
    box.on_bump(box.inner.count)
end

function make_box(callback: function (integer): ()): Outer
    return { inner = { count = 0 }, on_bump = callback }
end
```

Record fields may hold function values (top-level functions, lambdas, record functions, or bound methods) and other records. Reading or writing a nonexistent field is a compile-time error.

### `const` fields

Prefix a field with `const` (after `local`, if present) to prevent replacing that field after construction:

```titan
record Request
    const method: string
    local const token: string?
    headers: {string: string}
end

function Request.new(method: string, token: string?): Request
    return { method = method, token = token, headers = {} }
end

function Request:add_header(name: string, val: string)
    self.headers[name] = val
end
```

Construction fills `const` fields normally, and every subsequent Titan assignment or Lua field write is rejected.

Field constness is shallow. Declaring `const headers: {string: string}` prevents reassigning `req.headers = other`, while still allowing `req.headers["Host"] = "example.com"`. Use `const { T }` ([Arrays, Maps, and Iteration](arrays-maps.md)) when an Array container itself must be read-only. Likewise, reading a `const` embedded C struct or fixed array yields a borrowed pointer whose slot cannot be replaced; mutability of the pointed-to bytes is governed by C `const` ([Calling C](ffi.md)).

### `local` fields

A `local` field is real per-instance storage that only the defining module (and explicit `.titan` source imports) may read or write. Ordinary importing modules and Lua code see only public fields; attempting to access a `local` field reports the same error as an absent field. Field visibility and `const` are independent (`local const` is both private and read-only).

## Methods and record functions

### Instance methods

Methods are declared at top level using colon syntax and receive an implicit `self` parameter of the record's type:

```titan
record Span
    start: integer
    finish: integer
end

function Span:length(): integer
    return self.finish - self.start
end

local function Span:clamp_end(limit: integer)
    if self.finish > limit then
        self.finish = limit
    end
end

function bounded_length(span: Span, limit: integer): integer
    span:clamp_end(limit)
    return span:length()
end
```

Put private operations on a record as `local` methods rather than free functions taking the record as a first parameter. A `local` method is callable only inside the defining module (and explicit `.titan` source imports) and is absent from the Lua metatable.

Method rules:

- Methods and fields share one member namespace: a method cannot have the same name as a field, and a method cannot be declared twice.
- Methods are not fields. `span.length` is a compile-time error in Titan; always use colon syntax.
- Method calls are resolved statically at compile time.
- Methods may declare variadic inputs (`...: T`) and flexible return tails (`(...: T)`), just like module functions.

### Bound method references

Naming a method with a colon and no call arguments produces a first-class function value with `self` bound and removed from the parameter list:

```titan
record Accumulator
    total: integer
end

function Accumulator:add(n: integer): integer
    self.total = self.total + n
    return self.total
end

function make_adder(acc: Accumulator): function (integer): (integer)
    return acc:add
end
```

The receiver expression is evaluated once when the bound reference is created and captured by reference, so calls through the bound function mutate `acc`. Bound method references are covered further in [First-Class Functions and Closures](closures.md).

### Record functions

A record function is a static function attached to the record's namespace with a dot. It has no implicit `self` parameter:

```titan
record Color
    r: integer
    g: integer
    b: integer
end

function Color.black(): Color
    return Color(0, 0, 0)
end

local function Color.clamp(channel: integer): integer
    if channel < 0 then return 0 end
    if channel > 255 then return 255 end
    return channel
end

function Color.rgb(r: integer, g: integer, b: integer): Color
    return Color(Color.clamp(r), Color.clamp(g), Color.clamp(b))
end
```

Record functions (`Color.black`, `Color.new`) are first-class function values and may be declared `local`, variadic, or flexible-returning. The record name `Color` itself is not a value.

### Optional receivers

A record option `Point?` automatically unwraps with a runtime nil check wherever a plain `Point` is required, including field reads, field writes, and method calls. Check for `nil` once, then use the value directly without an explicit `as` cast:

```titan
record Entry
    label: string
end

function Entry:describe(): string
    return "entry: " .. self.label
end

function format_entry(entry: Entry?): string
    if not entry then
        return "missing"
    end
    return entry:describe()
end
```

Calling `entry:describe()` on a `nil` value raises a runtime type error naming the record type (see [Type Aliases, Options, and Dynamic `value`](types.md)).

## Across modules, Interfaces, and Lua

An exported record can be imported and used across modules by its qualified name (`geo.Point`). Record identity is shared across the entire Lua state for a given `(module, RecordName)` declaration, while same-named records in different modules remain distinct types.

A record does not declare an `implements` clause to satisfy an [Interface](interfaces.md). At any conversion site expecting an Interface, Titan checks structurally that the record has every required `const` field and method visible at that site, then constructs a fresh Interface wrapper.

### From Lua

To Lua, a Titan record instance is a userdata value (`type(p) == "userdata"`) with a protected metatable (`getmetatable(p)` returns `"Titan record module.Name"`):

```lua
local geo = require "geometry"

local p = geo.Point(1, 2) -- calls Point.new when new is public
print(type(p))            --> userdata
p:move(3, 4)              -- colon method call
print(p.x, p.y)           --> 4.0  6.0
p.x = 10                  -- checked dynamic conversion (10 -> 10.0)
```

Lua observes the following rules:

- **Namespace table.** Each exported record appears on its module table as a namespace holding its public record functions. When `new` is public, the namespace has a `__call` metamethod that forwards arguments to `new` without passing the namespace itself. Lua's `geo.Point { ... }` still passes a single table argument—named calls are Titan compile-time syntax.
- **Checked fields and methods.** Reading or writing a missing or `local` field raises an error. Writes to mutable fields run Lua-boundary type conversion; writes to `const` fields raise a const-write error. Public methods are callable via `p:move(...)` and cannot be overwritten through field assignment.
- **Identity and non-table semantics.** Equality (`==`) compares object identity in both Titan and Lua. Records cannot be bracket-indexed, measured with `#`, iterated as tables, or given custom metatables.

Because each record is a single GC-managed userdata holding its fields at fixed offsets, field reads and writes compile to constant-offset loads and stores, and direct Titan method calls compile to static C calls without hashing or vtable indirection.
