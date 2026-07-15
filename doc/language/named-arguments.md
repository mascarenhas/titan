# Named arguments

Titan has a named-only call form for calls whose target is a declaration:

```lua
record Point
    x: float
    y: float
end

function move(dx: integer, dy: integer)
end

function Point:translate(dx: float, dy: float)
    self.x, self.y = self.x + dx, self.y + dy
end

local function example(point: Point)
    move { dx = 10, dy = 20 }
    point:translate { dy = 20, dx = 10 }
    local copy = Point.new { y = 3.0, x = 2.0 }
end
```

The compiler matches each label to a declared parameter, type-checks the
result, and lowers the call to Titan's ordinary positional calling convention.
There is no run-time name lookup or argument table.

## Braces select named syntax

A bare brace suffix always starts a named call, including the empty form:

```lua
f { x = 1 }
f{x = 1}       -- whitespace is not significant
f {}
f{}
object:m { x = 1 }
object:m{}
```

Parentheses select positional syntax. A constructor passed as one positional
argument must therefore be parenthesized:

```lua
consume_record({ x = 1 })
consume_array({ 1, 2 })
consume_map({ ["x"] = 1 })
consume_empty({})
```

The older Lua-style spelling `consume_record { x = 1 }` does not mean a
one-argument positional call in Titan: it is a named call to
`consume_record`, with an argument named `x`. Bare-string call sugar remains
positional, so `print_line "hello"` still passes one string.

A named list contains only `label = expression` items. Commas and semicolons
are interchangeable separators, and a trailing separator is allowed:

```lua
configure {
    path = "/tmp/data";
    enabled = true,
}
```

Positional items, computed labels, `...`, and mixtures of positional and named
arguments are syntax errors. A label uses an identifier's raw spelling, so a
Titan keyword is legal in this one position. This matters for C APIs:

```lua
libuv.uv_timer_start {
    handle = timer,
    cb = callback,
    timeout = 100,
    repeat = 10,       -- `repeat` is a keyword elsewhere
}
```

The keyword remains unavailable as a variable, function, record field, or
ordinary member name.

## Which calls support names

Named syntax is deliberately tied to declarations that publish a canonical
parameter list:

| Call target | Named syntax |
| --- | --- |
| A directly named local or exported Titan function | Yes |
| An imported Titan module function | Yes |
| A record static function, including `Rec.new` | Yes |
| A direct record method call | Yes; the implicit receiver is not a named parameter |
| A direct, fixed-arity C function with complete, unique prototype names | Yes |
| A function value, anonymous function, or bound-method value | No |
| A C function-pointer value or C pseudo-constructor such as `T.new` | No |
| Any Titan or C variadic function | No |

In particular, storing a declaration in a variable loses its declaration
provenance for named-call purposes even though the value remains callable:

```lua
function add(left: integer, right: integer): integer
    return left + right
end

local function use()
    local direct = add { right = 2, left = 1 } -- accepted
    local fn = add
    local indirect = fn { right = 2, left = 1 } -- compile-time error
end
```

Parameter names belong to the source API, not to structural function types.
Renaming an exported parameter can therefore break a named caller when that
caller is recompiled, but it does not change function-type compatibility, the
native symbol, or the binary calling convention. The same distinction applies
to parameter spellings in C headers.

## Matching, checking, and omission

Names may appear in any order. The compiler rejects unknown names and rejects
a name supplied more than once. Each supplied expression is checked against
its matched formal and receives the ordinary implicit argument coercions.

Every omitted formal is treated as a synthesized `nil`. The omission is
accepted only when that formal's type accepts or can coerce `nil`. This includes
option types, `value`, `boolean`, `nil`, and nullable pointer forms. Required
numbers, strings, containers, records, and functions cannot be omitted.

```lua
function configure(label: string?, enabled: boolean, payload: value)
end

local function apply()
    configure { enabled = true } -- label and payload receive nil
    configure {}                 -- accepted: all three types accept nil
end
```

For `boolean`, the existing nil-to-boolean coercion produces `false`. This is
the same adjustment rule used by missing positional arguments to Titan
functions. A parenthesized direct C call keeps strict C arity, but a supported
named C call may omit a fixed parameter when its Titan-visible type accepts
`nil`; an omitted pointer, for example, becomes `NULL`.

The empty form `f {}` is therefore not simply another spelling of `f()`: it
requests named matching and nil-fills every formal. It also requires a target
that supports named calls.

## Evaluation order

For a method, the receiver is evaluated exactly once before any argument.
Explicit named expressions are then evaluated exactly once, from left to right
as written. Reordering names changes positions at the call boundary, not the
order of effects:

```lua
target {
    third = mark(1),
    first = mark(2),
    second = mark(3),
}
```

The calls to `mark` occur in the order `1`, `2`, `3`; if the formal order is
`first, second, third`, the callee receives `2, 3, 1`.

Each named item supplies exactly one formal. A multi-return call used as a
named expression contributes only its first return value, even in the final
item; the trailing multi-return expansion of positional argument lists does
not apply.

## Record construction

The synthesized record static `Rec.new` is an ordinary named-call target:

```lua
local p = Point.new { y = 3.0, x = 2.0 }
```

Context-typed record constructor expressions use the same omission rule:

```lua
record Config
    label: string?
    enabled: boolean
    payload: value
end

local a: Config = {}
local b: Config = { label = "test" }
```

Missing fields are filled with `nil` when their types permit it; a missing
non-nil-compatible field is a compile-time error. Explicit fields retain
constructor semantics rather than named-call semantics: if an explicit field
is repeated, both expressions are evaluated in source order and the last store
wins.

A record with any local field still cannot be constructed with `{...}` outside
its declaring module, even if every local field could accept `nil`. Inside the
declaring module, omitted public and local fields follow the same nil rule.

See [Records](records.md#creating-records) for the two record construction forms.

## C prototype names

A direct foreign function supports names only when its effective fixed
prototype supplies one complete, unambiguous list of unique parameter names.
A true zero-parameter prototype, `f(void)`, publishes an empty list and accepts
`f{}`. An old-style declaration `f()` does not publish parameter metadata.
Unnamed parameters, duplicate names, partial lists, or conflicting names across
compatible redeclarations make named syntax unavailable for that declaration;
the positional call remains usable.

C function pointers do not acquire named-call support from names written in a
typedef. They are callable values rather than direct declaration members.
Named calls to C variadic functions are also rejected, even when all fixed
arguments are present. See [The C FFI](ffi.md#calling-c-functions).

## Calls from Lua stay positional

Lua does not carry Titan's named-call syntax marker. In Lua,
`module.f { x = 1 }` is simply `module.f({ x = 1 })`: one ordinary table
argument. Titan does not infer names from the table's keys, arity, or contents,
and generated Lua entry wrappers continue to adjust and check arguments by
position. An explicit tagged API would be needed for any future Lua-side named
call design.
