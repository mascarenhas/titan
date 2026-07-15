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
side can be any Titan type: a basic type, array, map, option, function type, or
record type. Alias chains and forward references are allowed. An alias cycle,
including a cycle through a compound type, is a compile-time error.

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

A record alias preserves the original record's nominal identity and methods:

```titan
local geometry = import "geometry"

type Point = geometry.Point

function move(p: Point): Point
    return p:move(1.0, 1.0)
end
```

`Point` above is still `geometry.Point`; it is not a second record with the
same fields.

## Type names are not values

Aliases occupy a type-only namespace. They may share a spelling with a
variable or function, but not with another alias or record type. An alias can
appear in annotations and casts; it cannot be evaluated, assigned, called, or
used as a record namespace:

```titan
type Point = geometry.Point

-- Point.new(...) is invalid: Point is not a run-time module member.
-- Construct through the module that owns the record instead.
local p: Point = geometry.Point.new(1.0, 2.0)
```

This also means a Lua caller never sees a member created for an alias.

## Visibility and re-exports

A public alias is part of its module's compiled type interface. Importers use
the alias through the importing module's qualifier:

```titan
-- shapes.titan
local geometry = import "geometry"
type Point = geometry.Point

function origin(): Point
    return geometry.Point.new(0.0, 0.0)
end
```

```titan
-- draw.titan
local shapes = import "shapes"

function draw_origin()
    local p: shapes.Point = shapes.origin()
    p:move(10.0, 5.0)
end
```

Only `shapes` is an explicit import of `draw`; the alias still resolves to the
record owned by `geometry`. When these modules are separate shared libraries,
initializing `shapes` loads `geometry` globally before `draw` resolves the
record's method entry points. `draw` therefore does not separately open
`geometry`.

A `local type` alias is visible only inside its defining module and is omitted
from the compiled interface. As with other exported declarations, the target
of a public alias must itself be exportable: it cannot contain a local record
or a C-FFI type. A local alias may name either.

Imports remain source ordered. A qualified alias target is resolved at its
earliest use, so the corresponding `import` must precede that use (and must
precede the alias declaration when resolving the declaration itself is the
earliest use).
