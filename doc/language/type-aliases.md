# Type aliases

A type alias gives an existing Titan type another compile-time name. It does
not declare a new type or create a run-time value.

```titan
type UserId = integer
type Handler = (string) -> boolean
type MaybeHandler = Handler?

local type Scratch = {string}
```

The syntax is `type Name = T`, with optional `local` visibility. The right-hand
side can be any Titan type: a basic type, array, map, option, function type,
record type, union type, or Interface. A union variant is not a type and
therefore cannot appear here. Alias chains and forward references are allowed.
An alias cycle, including a cycle through a compound type, is a compile-time
error.

## Transparent identity

Aliases are transparent. Every use resolves to the exact type object denoted
by the right-hand side, so aliases introduce no conversion and do not affect
type equality:

```titan
type Count = integer
type Counts = {Count}

function total(xs: Counts): Count
    local n: integer = 0
    for i = 1, #xs do
        n = n + xs[i]
    end
    return n
end
```

A record, union, or Interface alias preserves the original nominal identity
and methods:

```titan
local geometry = import "geometry"

type Point = geometry.Point

function move(p: Point): Point
    return p:move(1.0, 1.0)
end
```

`Point` above is still `geometry.Point`; it is not a second record with the
same fields.

Likewise `type Event = messages.Message` denotes that exact union. It does not
create new variants or a second constructor namespace: `Event.write(...)`
selects the original `messages.Message.write` constructor. `type Write =
messages.Message.write` is still invalid because a variant is not a first-class
type.

Likewise, `type Input = io.Reader` denotes that exact nominal Interface. It
does not copy the method set into a structurally interchangeable new type and
does not create an `Input` run-time namespace.

## Nominal static namespaces

Aliases occupy a type-only namespace. They may share a spelling with a
variable or function, but not with another alias, record type, union type, or
Interface. An alias can appear in annotations and casts; it cannot itself be
evaluated, assigned, or called.

An alias to a record or union does, however, preserve the original nominal
type's static namespace. This is selector syntax resolved at compile time, not
a first-class alias value or a new run-time namespace:

```titan
type Point = geometry.Point
type Event = messages.Message

local p: Point = Point.new(1.0, 2.0)
local make_point: (float, float) -> Point = Point.new
local event: Event = Event.write("hello")
```

A constructor-preserving alias to a bare generic owner is itself applicable:
`type Crate = Box` permits `Crate<integer>.new(1)`. A concrete alias such as
`type IntBox = Box<integer>` is already closed and uses `IntBox.new(1)`; it
cannot receive another owner list.

Record aliases expose the original record's visible record functions,
including its synthesized `new` when that constructor is public. A record with
one or more `local` fields has a local synthesized `new`, so an alias in another
module does not expose it. Union aliases likewise expose the original union's
visible variant constructors and public union functions. Ordinary visibility
still applies: an alias never makes a local record function or local variant
constructor public.

Interfaces have methods on values but no static namespace, so an Interface
alias is usable only as a type. Aliases to non-nominal types likewise do not
become expressions. If an ordinary value has the same spelling as an alias,
ordinary expression lookup selects that value.

No alias member is added to the run-time module object. Consequently a Lua
caller never sees a member created for an alias, even though Titan code can use
the compile-time nominal selector syntax above.

## Visibility and re-exports

A public alias is part of its module's compiled type interface. Importers use
the alias through the importing module's qualifier:

```titan
-- shapes.titan
local geometry = import "geometry"
type Point = geometry.Point

function origin(): Point
    return Point.new(0.0, 0.0)
end
```

```titan
-- draw.titan
local shapes = import "shapes"

function draw_origin()
    local make_point: (float, float) -> shapes.Point = shapes.Point.new
    local p = make_point(0.0, 0.0)
    p:move(10.0, 5.0)
end
```

Only `shapes` is an explicit import of `draw`; both the constructor and methods
still belong to the nominal type owned by `geometry`. When these modules are
separate shared libraries, initializing `shapes` loads and initializes
`geometry` before `draw` resolves its native entry points and original module
state. `draw` therefore does not separately open `geometry`. The same ownership
is preserved through static providers and chains of aliases.

A `local type` alias is visible only inside its defining module and is omitted
from the compiled interface. As with other exported declarations, the target
of a public alias must itself be exportable: it cannot contain a local record
or union
or a C-FFI type. A local alias may name either.

Aliases and their targets are order-independent within a module. In
particular, a qualified alias target may use an import declared later:

```titan
type Point = geometry.Point
local geometry = import "geometry"
```

The alias may itself be used by earlier record fields, union payloads, and
callable signatures.
The ordinary module-variable frontier still applies: a module-variable
declaration can use any alias in the module, but it cannot directly use a
qualified import alias that occurs later in the logical source order. See
[Declaration order and visibility](modules.md#declaration-order-and-visibility).
