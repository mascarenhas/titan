# Unions

Titan unions are nominal tagged values. A union declaration lists a fixed set
of named variants; each variant either carries one payload value or carries no
payload. Construction is explicit through a generated function, and inspection
is explicit through a `case` statement.

```titan
record Point
    x: float
    y: float
end

union Message
    quit
    write: string
    move: Point
end

function describe(message: Message): string
    case message
    when write: text then
        return "write: " .. text
    when move: point then
        return "move to " .. point.x .. ", " .. point.y
    when quit then
        return "quit"
    else
        return "unknown"
    end
end
```

Every arm begins with the reserved word `when`. There is no fallthrough:
exactly the matching arm runs. The optional `else` runs when no listed arm
matches.
`when` is reserved in ordinary Titan names, but a C header member or qualified
C type spelled `when` remains source-nameable through the FFI's
[contextual C-name rule](c-ffi-expressions.md#titan-keywords-as-c-names).

## Declaring unions and variants

The general form is:

```titan
[local] union Name
    [local] empty_variant
    [local] payload_variant: PayloadType
    ...
end
```

A union must declare at least one variant. Variant names are unique within the
union. A `local union` and a `local` variant are visible only inside their
declaring module. Local variants still consume their declaration-order tag:
making a variant local does not renumber the public variants around it.

The union is a type. Its variants are metadata belonging to that type, not
separate types. In particular, `Message.write` is a constructor function, not
a type name, and is illegal in a type annotation, a type alias, or on the
right-hand side of `as` or `is`. Use `Message` as the type and use `case` to
distinguish its values.

Union types are nominal. Two declarations with the same variants are still
different types:

```titan
union First
    item: integer
end

union Second
    item: integer
end

-- First.item(1) is not a Second
```

Transparent aliases preserve the original union identity:

```titan
type Event = Message
```

## Constructors

Each variant declaration synthesizes one static constructor named
`Union.variant`. An empty variant takes no parameter; a payload variant takes
exactly one parameter of the declared payload type.

```titan
local stopped = Message.quit()
local line = Message.write("hello")
local moved = Message.move(Point.new(10.0, 20.0))
```

Variant constructors are ordinary first-class function values:

```titan
local make_message: (string) -> Message = Message.write
local message = make_message("hello")
```

They use the normal fixed-call argument adjustment: omitted fixed arguments
are nil-filled and surplus arguments are evaluated and discarded. The
resulting value must still satisfy the declared payload type.

Variant constructors are deliberately **positional-only** in this version.
The named-call spelling is not accepted:

```titan
-- not valid
local message = Message.write { value = "hello" }
```

The braces-only call form is Titan's named-argument syntax, not record payload
syntax. When the payload itself is a record, keep the ordinary parentheses
around the positional argument:

```titan
local message = Message.move({ x = 10.0, y = 20.0 })
```

The same rule applies through an imported union:

```titan
-- messages.titan
record Delta
    x: float
    y: float
end

union Message
    move: Delta
end
```

```titan
-- message_consumer.titan
local m = import "messages"
local moved = m.Message.move({ x = 1.0, y = 2.0 })

-- invalid: without the parentheses this is a named call, and generated
-- variant constructors publish no parameter names
-- local bad = m.Message.move { x = 1.0, y = 2.0 }
```

User-declared union functions and methods use the same syntax and rules as
record functions and methods:

```titan
function Message.default(): Message
    return Message.quit()
end

function Message:length(): integer
    case self
    when write: text then
        return #text
    else
        return 0
    end
end
```

A generated constructor reserves its variant name in the union's static
function namespace. User-declared union functions may use named calls in the
same declaration-based situations as record functions; only generated variant
constructors are forced to remain positional.

A genuine generated variant constructor is also a constant-expression form
when its one payload argument is recursively constant (or when the variant is
empty), so it may initialize a module variable. The checker recognizes the
validated synthesized constructor metadata, not merely any static returning
the owner: a user-written union function that happens to return `Message` is
still an ordinary nonconstant call.

## Payload types

A payload occupies the same run-time kind of value slot as a record field.
Consequently the eligible payload types are exactly the eligible record-field
types.

Ordinary Titan values are eligible, including primitive values, strings,
arrays, maps, records, unions, Titan function values, option types, and
`value`. C scalars and object pointers that can be boxed as a Titan value are
also eligible, as are the supported exact `TValue`/`Udata *` and owned-storage
forms.

Direct C aggregates, C arrays, direct C functions, and C function pointers are
not eligible payloads. An option is eligible only when its base is eligible.
Arrays, Maps, and Titan function values are already boxed values, so their
element, key/value, or signature types are not recursively subjected to this
direct-storage test.

An empty variant has no hidden user payload. It is therefore an error to bind
one in a `case` arm.

## Case statements

A case statement has one scrutinee, one or more `when` arms, and an optional
`else`:

```titan
case expression
when variant_name[: binding] then
    block
when another_variant[: binding] then
    block
else
    block
end
```

The scrutinee must have the union's type. A payload arm may introduce one
binding after `:`; the binding has the variant's payload type. An empty
variant cannot have a binding. Repeating the same variant in a case statement
is an error.

Binding follows ordinary local-assignment value semantics. Scalar payloads
are copied; identity- or reference-bearing payloads such as records, arrays,
maps, unions, and functions keep the same underlying object. Mutating a
mutable record or container through the binding is therefore visible through
every other alias.

The binding is scoped to that arm. Each arm and the `else` clause is a regular
Titan block, not merely a list of simple statements. It can therefore contain
nested declarations and control flow and can carry its own `catch` and
`finally` clauses:

```titan
case message
when write: text then
    defer log(text)
    consume(text)
catch
    report(text)
finally
    finish(text)
when quit then
    stop()
finally
    release()
else
    ignore()
end
```

The arm binding is visible in that arm's protected body, `catch`, and
`finally`. Locals declared inside the protected body follow the ordinary
error-handling scope rule and are not visible in sibling `catch` or `finally`
clauses.

`defer` needs no case-specific behavior: it is transformed within the arm or
`else` block that contains it, runs at that block's exit, and never extends
into another arm.

`break` in an arm targets the enclosing loop, just as it does from an
`if`/`elseif`/`else` block. There is no implicit loop and no fallthrough
between arms.

## Non-exhaustiveness and control-flow analysis

Case statements are intentionally non-exhaustive. The compiler does not
require every variant to be listed, and it does not insert an implicit error.
If no arm matches and there is no `else`, the case statement does nothing and
execution continues after it.

For control-flow analysis, a case statement is exactly like an
`if`/`elseif`/`else` chain. It is considered non-fallthrough only when:

1. it has an explicit `else`; and
2. every `when` arm and the `else` block is non-fallthrough.

Listing every currently declared variant does not substitute for the explicit
`else`.

## Option scrutinees

The ordinary option auto-unwrapping rule applies to case scrutinees. A
`Message?` expression is automatically forced to `Message` before dispatch:

```titan
function inspect(message: Message?)
    case message
    when quit then
        stop()
    else
        continue()
    end
end
```

If the value is nil, the force raises the same run-time error as another
automatic option unwrap. Nil is not an unlisted variant and does not select
`else`.

## Equality, conversions, and field access

Union values are identity-bearing userdata, like records. Equality compares
value identity, not variant and payload contents. A union has no public
`.tag`, `.payload`, or variant fields; use `case` to inspect it.

The union type participates in ordinary conversions to and from `value`, with
the usual checked nominal conversion on the way back. An explicit cast to C
`void *` exposes the identity pointer, as it does for a record.

Titan unions are not C unions, just as Titan records are not C structs. There
is no cast between a Titan union and a C `union`, C `struct`, or other
structural aggregate. C code that needs a Titan identity may use only the
documented `void *` identity cast.

## Unions and Interfaces

A union can satisfy an [Interface](interfaces.md) through its visible public or
module-local methods, exactly as a record can. The union does not carry an
`implements` annotation. At each statically known conversion site, every
required Interface method must be visible and satisfy the Interface signature
under directional callable adjustment; variants, constructors, payloads, and
union functions do not count.

An accepted `U -> I` conversion constructs a fresh Interface wrapper retaining
the union value. It is a direct coercion rather than subtyping or gradual
consistency, and it does not lift through a container or function component.
Interface equality compares wrapper identity, so the wrapper is incomparable
with its concrete union and separately constructed wrappers are distinct.
Inside Interface dispatch the concrete `self` is still the exact union value,
including its variant tag and payload.

## Visibility and declaration order

Union declarations follow the current record visibility rules.

Within one module, a union and its variants, generated constructors, methods,
and union functions are available module-wide, regardless of written order.
An imported union is likewise available to aliases, record fields, union
payloads, callable signatures, and function bodies even when the relevant
`import` appears later.

Module-variable initializers retain their declaration frontier. A direct
qualified use of an imported union constructor, or the same use nested in a
lambda evaluated by that initializer, sees only earlier imports. A type alias
may bridge to a later import because aliases use the placement-independent
type declaration frontier.

These rules are identical in flat and folder modules: contributor files add
source order but do not introduce file-local namespaces.

## Lua interoperability

From Lua, an exported union name is a read-only namespace on its Titan module.
It contains public variant constructors and public user-declared union
functions. Constructor function identity is stable, so repeated reads compare
equal.

A union value is userdata. Public methods are available through ordinary
method lookup. Variants, tags, and payloads are opaque; arbitrary reads and
all writes fail. The protected metatable string is
`"Titan union <qualified-name>"`.

```lua
local m = require "messages"
local value = m.Message.write("hello")
print(value:length())
print(getmetatable(value)) -- Titan union messages.Message
```

Lua arguments and results cross the same checked boundary as records. A value
passed where a particular union is required must carry that exact nominal
union identity.

## Version-one boundaries

Union version one deliberately keeps the model small:

* each variant carries zero or one payload value;
* variants are not first-class types;
* constructors are positional-only;
* case analysis is non-exhaustive;
* no variant/tag/payload reflection is exposed to Titan or Lua;
* there is no structural conversion to a C union; and
* equality is identity equality rather than derived value equality.

The compiled-module interface carries union and variant metadata so imported
modules preserve constructor, method, visibility, and tag information. That
interface and the corresponding run-time layout begin at compiled-module ABI
0.19.
