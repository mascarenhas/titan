# Tagged Unions and Pattern Matching

A tagged union represents a closed set of named alternatives, each carrying zero or more typed payload parts. Values are constructed through generated variant constructors and inspected with `case` statements.

```titan
union Message
    quit()
    write(string)
    move(x: float, y: float, note: string?)
end

function describe(message: Message): string
    case message
    when write(text) then
        return "write: " .. text
    when move { y, x, comment = note } then
        local suffix = comment and (" (" .. comment .. ")") or ""
        return "move to " .. x .. ", " .. y .. suffix
    when quit() then
        return "quit"
    end
end
```

Every arm starts with `when`. Only the matching arm runs—there is no fallthrough between arms—and an optional `else` arm runs when no listed variant matches.

## Declaring a union

Union declarations appear at module top level and must contain at least one variant:

```text
[local] union Name
    [local] empty_variant()
    [local] single_part(PayloadType)
    [local] named_parts(first: FirstType, second: SecondType)
end
```

Each variant declares a fixed list of payload parts:

- `quit()` declares an empty variant with no payload.
- `write(string)` is shorthand for a single named part `write(value: string)`.
- `move(x: float, y: float, note: string?)` declares explicit `name: Type` parts (up to 65,534 parts per variant).

A variant cannot mix unnamed shorthand with named parts, cannot repeat a part name, and cannot use a variadic `...: T` tail. Variant names and part names accept any ASCII identifier (including reserved words such as `end`), while local `case` binders use ordinary non-reserved identifiers (see [Appendix C: Grammar Reference](grammar.md)).

Choose variant payload parts for data specific to that alternative; use a [record](records.md) when the data has its own methods, mutable shared state, or reusable identity across multiple contexts.

### Nominal identity and visibility

Unions are nominal types identified by their fully qualified declaration name (`module.UnionName`). Two separate declarations with identical variants are unrelated types, while a transparent `type` alias preserves the same union identity.

A union is a type; its variants are not separate types. `Message.write` is a constructor function, not a type name, and cannot appear in a type annotation, a `type` alias, or after `as`/`is`.

A `local union` or `local` variant is visible only inside its defining module (and explicit `.titan` source imports). Within a module, a union and all of its constructors, methods, and functions are visible regardless of source order.

### Payload types

Union payload parts accept the same types as record fields: all ordinary Titan types (scalars, strings, containers, records, unions, Interfaces, functions, options, and `value`), foreign scalars and pointers, and eligible fixed C structs, unions, and arrays. Embedded C structs and fixed arrays project borrowed interior pointers when matched in `case` (see [Calling C](ffi.md)).

## Variant constructors

Each variant generates a static constructor `Union.variant` whose parameters match its payload parts in declaration order. Direct calls accept both positional and named arguments ([Functions, Arguments, and Results](functions.md#named-calls)):

```titan
union Message
    quit()
    write(string)
    move(x: float, y: float, note: string?)
end

function build_messages(): (Message, Message, Message, Message)
    local stop = Message.quit()
    local line = Message.write("hello")
    local labeled = Message.write { value = "hello" }
    local moved = Message.move { y = 20.0, x = 10.0 } -- note receives nil
    return stop, line, labeled, moved
end
```

Constructor call rules:

- Positional calls follow standard fixed-arity adjustment: omitted trailing arguments are filled with `nil` and type-checked, and surplus arguments are evaluated and discarded.
- Named calls evaluate explicit expressions in written order. Any omitted part receives `nil` and must accept it (for example `T?`, `value`, or `boolean` converting to `false`); omitting a required `integer` or `string` is a compile-time error.
- For a generic union, explicit owner type arguments attach to the union name: `Maybe<|integer|>.present(1)` and `Maybe<|integer|>.absent()`.
- Variant constructors are first-class function values (`local make: function (string): (Message) = Message.write`). Once stored in a function variable, the constructor is called positionally.
- Generated variant constructors (including empty variants) may be called in module-variable initializers, subject to the [initializer dependency rules](modules.md).

Because bare braces select named-call syntax, keep parentheses when passing a record constructor as a single positional payload part, or name the part explicitly:

```titan
record Point
    x: float
    y: float
end

union Movement
    step(Point)
end

function make_steps(): (Movement, Movement)
    local first = Movement.step({ x = 1.0, y = 2.0 })
    local second = Movement.step { value = { x = 1.0, y = 2.0 } }
    return first, second
end
```

## Matching with `case`

A `case` statement dispatches on a union value across zero or more `when` arms and an optional `else` arm:

```text
case expression
when variant_name(a, b) then
    block
when other_variant { part, local_alias = other_part } then
    block
else
    block
end
```

### Positional and named bindings

- **Positional (`when move(a, b)`):** Binds parts in declaration order. Any trailing parts may be omitted (including all parts, `when move()`), and binder names need not match the declared part names. Extra binders or any binder on an empty variant are compile-time errors.
- **Named (`when move { vertical = y, x }`):** Selects parts by name in any order. Writing `x` binds part `x` to a local named `x`; writing `alias = part` puts the **local variable on the left** and the **declared part name on the right**. Commas and semicolons are optional separators (including a trailing separator). Any part may be omitted regardless of its type—unlike constructors, matching imposes no nil requirement on omitted parts. Referring to an unknown part or naming the same part twice is an error.

When a variant part has a reserved-word name such as `end`, alias it to a regular identifier when matching:

```titan
union SpanEvent
    closed(from: string, end: integer, reason: string)
end

function format_event(event: SpanEvent): string
    case event
    when closed { finish = end, summary = reason } then
        return summary .. " at " .. finish
    end
end
```

Repeating the same variant in two `when` arms of one `case` is a compile-time error.

Binding follows ordinary local assignment semantics: scalar values are copied, while records, Arrays, Maps, unions, and functions share the underlying reference. Embedded C structs and fixed arrays bind borrowed pointers into the union value, which remain valid while the union stays live.

### Arm blocks, `defer`, `catch`, and `break`

Each `when` arm and the `else` clause is a full Titan block with its own lexical scope. Payload binders are visible throughout that arm's body and in an arm-local `catch` clause (locals declared inside the arm body are not visible in `catch`). `defer` inside an arm runs when that arm exits, and `break` targets the enclosing loop:

```titan
local io = import "io"

union Job
    run(string)
    stop()
end

local function execute_job(name: string)
    if name == "" then
        raise "empty job name"
    end
end

function dispatch(job: Job): string
    case job
    when run(name) then
        defer io.print("finished " .. name)
        execute_job(name)
        return "ok: " .. name
    catch
        return "failed " .. name .. ": " .. (error as string)
    when stop() then
        return "stopped"
    end
end
```

### Option scrutinees

A `case` scrutinee of option type `U?` is automatically unwrapped before dispatch, just like a field read or method call on an optional record:

```titan
union Signal
    ping()
    halt()
end

function classify(sig: Signal?): string
    if not sig then
        return "none"
    end
    case sig
    when ping() then
        return "ping"
    when halt() then
        return "halt"
    end
end
```

If a `nil` value reaches `case` without an earlier guard, the unwrap raises a runtime type error; `nil` is not an unlisted variant and never enters `else`.

## Coverage and non-fallthrough proof

`case` statements do not require exhaustive coverage. If no arm matches and there is no `else`, `case` simply does nothing and execution continues after `end`.

When a function must return a value on every path, however, Titan's control-flow analysis uses the closed variant set of the scrutinee's union type. A `case` statement is proven **non-fallthrough** when every `when` arm terminates (via `return`, `raise`, or `break`) and either:

1. the `when` arms cover **every variant** of the closed union; or
2. an explicit `else` arm is present and also terminates.

In the `describe` and `classify` functions above, listing every variant lets the function omit a dummy `else` clause cleanly. If complete coverage is followed by a redundant `else`, the compiler still type-checks the `else` block, though it cannot be reached at run time.

An imported public union may contain `local` variants declared inside its defining module. Importers cannot name those private variants, so listing every public variant does not cover the closed union; an importer must supply a terminating `else` to prove non-fallthrough. When relying on exhaustive coverage over a separately loaded shared-library union, adding a private variant to that shared library later is detected at load time (see [Appendix B: Toolchain and Linking](toolchain.md)).

## Methods, functions, equality, and Interfaces

Unions support static union functions (`function Message.default(): Message`) and instance methods (`function Message:length(): integer`) under the same rules as [records](records.md):

```titan
union Packet
    empty()
    bytes(string)
end

function Packet.none(): Packet
    return Packet.empty()
end

function Packet:size(): integer
    case self
    when bytes(data) then
        return #data
    when empty() then
        return 0
    end
end
```

Generated variant constructors reserve their variant names in the union's static function namespace.

Union values compare by reference identity (`==`), not by variant tag or payload contents. Instances have no `.tag` or `.payload` fields; use `case` in typed Titan code (see [Reflection](standard-library-reflect.md) for dynamic inspection and [JSON](standard-library-json.md) for named-part JSON serialization). Titan unions are distinct from C `union` types and have no structural cast to or from C aggregates.

A union can satisfy a **method-only** [Interface](interfaces.md) through its visible methods (variant constructors and union functions do not count). Because a union's payload depends on its active variant, a union cannot satisfy an Interface that declares fields.

## Unions from Lua

From Lua, an exported union appears on its module table as a read-only namespace holding its public variant constructors and public union functions. Each union instance is userdata (`type(v) == "userdata"`) with a protected metatable `"Titan union module.Name"`:

```lua
local packets = require "packets"
local p = packets.Packet.bytes("hello")
print(p:size())            --> 5
print(getmetatable(p))     --> Titan union packets.Packet
```

Public methods are callable through colon syntax, equality compares identity, and variant tags and payloads remain opaque from Lua (arbitrary reads and all writes fail). Passing a union value across the Lua boundary checks its exact nominal union identity.
