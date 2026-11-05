# Unions

Titan unions are nominal tagged values. A union declaration lists a fixed set
of named variants; each variant carries zero or more named payload parts. Construction is explicit through a generated function, and inspection
is explicit through a `case` statement.

```titan
union Message
    quit()
    write(string)
    move(x: float, y: float)
end

function describe(message: Message): string
    case message
    when write(text) then
        return "write: " .. text
    when move(x, y) then
        return "move to " .. x .. ", " .. y
    when quit() then
        return "quit"
    else
        return "unknown"
    end
end
```

Every arm begins with the reserved word `when`. There is no fallthrough:
exactly the matching arm runs. The optional `else` runs when no listed arm
matches.
`when` is reserved as a statement keyword. Declaration/member positions that
use `AnyName` still admit keyword spellings; local payload binders use ordinary
non-keyword names. See [the grammar](grammar.md).

## Declaring unions and variants

The general form is:

```text
[local] union Name
    [local] empty_variant()
    [local] payload_variant(PayloadType)
    [local] parts_variant(first: FirstType, second: SecondType)
    ...
end
```

A union must declare at least one variant. Variant names are unique within the
union. A `local union` and a `local` variant are visible only inside their
declaring module. Public variants receive tags first in their relative source
order; local variants follow in their relative source order. Adding or moving
a local variant therefore does not renumber existing public variants.

Part names are unique within each variant and may be reserved words. The
single unnamed form `write(string)` is shorthand for `write(value: string)`.
A variant may use that single-type shorthand or a list of `name: Type` parts;
it cannot mix the two. Payload lists have fixed arity: `...: Type` is not
allowed. A variant supports at most 65,534 parts.

The union is a type. Its variants are metadata belonging to that type, not
separate types. In particular, `Message.write` is a constructor function, not
a type name, and is illegal in a type annotation, a type alias, or on the
right-hand side of `as` or `is`. Use `Message` as the type and use `case` to
distinguish its values.

Union types are nominal. Two declarations with the same variants are still
different types:

```titan
union First
    item(integer)
end

union Second
    item(integer)
end

-- First.item(1) is not a Second
```

Transparent aliases preserve the original union identity:

```titan
type Event = Message
```

## Constructors

Each variant declaration synthesizes one static constructor named
`Union.variant`, with one parameter per part in declaration order. An empty
variant takes no parameters.

```titan
local stopped = Message.quit()
local line = Message.write("hello")
local moved = Message.move(10.0, 20.0)
```

For a generic union, explicit owner arguments attach to the union namespace:
`Maybe<|integer|>.present(1)` and `Maybe<|integer|>.absent()`. The old spelling
`Maybe.present<|integer|>(1)` is not an owner application. An inferred call may
remain `Maybe.present(1)`, and a result-only binder with no evidence closes by
the [generic final carrier rule](generics.md#instantiating-calls-and-constructors).

Variant constructors are ordinary first-class function values:

```titan
local make_message: function (string): (Message) = Message.write
local message = make_message("hello")
```

They use the normal fixed-call argument adjustment: omitted fixed arguments
are nil-filled and surplus arguments are evaluated and discarded. The
resulting value must still satisfy the declared payload type.

Direct variant constructors also accept named arguments. Names select parts;
explicit expressions evaluate in written order. Omitted parts receive nil and
must accept it, either directly or through an ordinary implicit conversion.
For example, `string?` and `value` accept nil, and `boolean` converts it to
false; a required `integer` or `string` cannot be omitted.

```titan
local message = Message.write { value = "hello" }
local moved = Message.move { y = 20.0, x = 10.0 }
```

These names also work through imported union namespaces and explicit generic
owner applications. A constructor stored in an ordinary function variable is
called positionally, following the usual [named-call rules](named-arguments.md).

A record can still be one payload part. Keep parentheses to pass a record
constructor positionally, or name the part in a named call:

```titan
record Point
    x: float
    y: float
end
union Movement
    move(Point)
end
local first = Movement.move({ x = 1.0, y = 2.0 })
local second = Movement.move { value = { x = 1.0, y = 2.0 } }
```

User-declared union functions and methods use the same syntax and rules as
record functions and methods:

```titan
function Message.default(): Message
    return Message.quit()
end

function Message:length(): integer
    case self
    when write(text) then
        return #text
    else
        return 0
    end
end
```

A generated constructor reserves its variant name in the union's static
function namespace. User-declared union functions may use named calls in the
same declaration-based situations as record functions.

A genuine generated variant constructor, including one for an empty variant,
may initialize a module variable: like a generated record constructor, it only
stores its checked arguments, which follow the
[initializer dependency rule](modules.md#initializer-dependencies). The checker
recognizes the validated synthesized constructor metadata, not merely any
static returning the owner: an own user-written union function that happens to
return `Message` is an own-function dependency, while a union function imported
from another module is an ordinary imported call.

## Payload types

Union parts have the same storage eligibility as record fields. Ordinary
Titan values are supported, including primitive values, strings, Arrays, Maps,
records, unions, functions, Options, and `value`. Foreign scalars and object or
function pointers retain their native values; exact `TValue`/`Udata *` and
`owned` forms remain traced.

Eligible complete C structs, C unions, and fixed C arrays are stored by value.
A case binder for one of these parts receives a borrowed interior pointer
(an element pointer for an array). Direct C function types remain ineligible;
a C function pointer is a separate supported type. By-value C aggregates and
arrays are not Option bases and do not become generally boxable in `value`,
Arrays, or Maps. See [Native storage in records and unions](nominal-storage.md)
for the complete rules, including fresh trailing allocations.

An empty variant has no hidden user payload. It is therefore an error to bind
one in a `case` arm.

## Case statements

A case statement has one scrutinee, a sequence of `when` arms, and an optional
`else`:

```text
case expression
when variant_name([binding, ...]) then
    block
when another_variant{[part, alias = other_part, ...]} then
    block
else
    block
end
```

The scrutinee must have the union's type. Parenthesized binders select parts
in declaration order. Any suffix may be omitted, including every part, and
binder names need not match part names. Extra binders are a type error. An
empty variant cannot have a binder.

Curly braces select parts by name, in any order. `part` binds that part to a
same-named local; `alias = part` binds it to the local on the **left**. A
reserved-word part must use an ordinary nonreserved alias:

```titan
union Event
    received(from: string, end: integer, text: string)
end
function describe_event(event: Event): string
    case event
    when received{body = text; finish = end} then
        return body .. " through " .. finish
    end
end
```

Both forms may omit any unneeded values without a nil/type restriction; named
binding can skip a middle part. Named binders may be separated by commas or
semicolons, with optional separators and an optional trailing separator.
Referencing a part twice is a syntax error, even with different aliases.
Selecting an unknown part is a type error. Binder names follow ordinary local
shadowing rules. Repeating the same variant in a case statement is also an error.

Binding follows ordinary local-assignment value semantics. Scalar payloads
are copied; identity- or reference-bearing payloads such as records, arrays,
maps, unions, and functions keep the same underlying object. Mutating a
mutable record or container through the binding is therefore visible through
every other alias. Embedded C aggregate and fixed-array parts instead project
borrowed pointers into the union. Their contents may be mutated through those
pointers unless the declared C type is const-qualified; keep the union alive
for the entire borrowed lifetime.

The binding is scoped to that arm. Each arm and the `else` clause is a regular
Titan block, not merely a list of simple statements. It can therefore contain
nested declarations and control flow and can carry its own `catch` clause:

```titan
case message
when write(text) then
    defer log(text)
    consume(text)
catch
    report(text)
when quit() then
    stop()
else
    ignore()
end
```

The arm binding is visible in that arm's protected body and `catch`. Locals declared inside the protected body follow the ordinary
error-handling scope rule and are not visible in the sibling `catch` clause.

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

Control-flow analysis can nevertheless use the closed set of variants in the
scrutinee's static union type. A case statement is considered non-fallthrough
when every `when` arm is non-fallthrough and either:

1. the arms cover every variant in that closed union; or
2. an explicit `else` exists and is non-fallthrough.

The first route does not make exhaustive coverage mandatory; it only proves
that execution cannot reach the following statement when coverage happens to
be complete. If complete coverage is followed by a redundant `else`, that
block is unreachable, so its ability to fall through does not defeat the
proof. The compiler still checks the block normally.

An imported public union can have variants that are local to its defining
module. Those hidden variants still count in the closed union's total but
cannot be named by the importer, so listing every visible variant is not
complete coverage there. Such a consumer needs a non-fallthrough `else` to
prove that the case cannot fall through.

For a separately loaded shared dependency, a consumer that relies on complete
coverage records that closed-inventory assumption. Adding a private variant
then rejects the unchanged consumer at load time, including when a redundant
falling-through `else` had been ignored because coverage was complete. An
independently terminating `else` needs no such assumption. Other consumers
continue to accept compatible private-variant changes, with ordinary
unmatched-case fallthrough preserved. See
[Replacing shared-library dependencies](binary-compatibility.md#private-union-variants-and-control-flow).

## Option scrutinees

The ordinary option auto-unwrapping rule applies to case scrutinees. A
`Message?` expression is automatically forced to `Message` before dispatch:

```titan
function inspect(message: Message?)
    case message
    when quit() then
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

A union can satisfy a method-only [Interface](interfaces.md) through its visible
public or module-local methods. It cannot satisfy an Interface that declares a
field, because a variant-dependent payload is not a stable record slot. The
union does not carry an `implements` annotation. At each statically known
conversion site, every required method must be visible and satisfy the
Interface signature under directional callable adjustment; variants,
constructors, payloads, and union functions do not count.

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
functions. Exact constructor source identity is stable, so repeated reads
compare equal. A later non-exact Titan target-typed use may conditionally
realize a fresh [closure adjustment wrapper](closure-adjustment-wrappers.md)
without changing that canonical source value.

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

## Boundaries

Unions retain these boundaries:

* each variant has a fixed list of named payload parts;
* variants are not first-class types;
* direct constructors support positional and named calls;
* case coverage is not required (complete coverage is only a control-flow
  proof);
* ordinary instance access keeps tags and parts opaque;
  [reflection](standard-library-reflect.md) provides typed inspection;
* there is no structural conversion to a C union; and
* equality is identity equality rather than derived value equality.

The compiled-module interface carries union and variant metadata so imported
modules preserve constructor, method, visibility, and tag information. That
interface and the corresponding run-time layout are part of the compiled-module
ABI. Public variant tags keep their relative order independently of private
variants. A separate shared provider may change private variants subject to
the selective compatibility and control-flow rules above. Rebuild affected
consumers when a required public shape or ABI changes; there is no layout
adapter.
