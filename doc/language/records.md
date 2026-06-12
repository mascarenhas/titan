# Records

Records are Titan's structured data type: named, fixed-shape values with
a declared set of typed fields, plus methods. They are the moral
equivalent of structs — fields live at fixed slots, so reading `p.x`
compiles to an indexed load, not a hash lookup. Unlike
[arrays and maps](arrays-maps.md), records are **not** Lua tables: they
are a distinct kind of value with their own identity, and they are typed
*nominally* — by which declaration they come from, not by what fields
they happen to have.

## Declaring a record

A record declaration may only appear at the top level of a module. Each
field is a name and a type; fields are separated by newlines or
semicolons (a trailing semicolon is fine):

```lua
record Point
    x: float
    y: float
end
```

Declaring the same field twice is a compile-time error
(`redeclaration of field 'x' in record 'Point'`).

An empty record (`record Empty end`) is legal: it can be constructed
with `Empty.new()` and crosses to Lua like any other record, though with
no fields or methods there is little you can do with one.

Records are **always exported**. There is no `local record` form (it is
a syntax error), and the record's name becomes a member of the module,
both for importing Titan modules and for Lua (see below).

A record's field types may mention the record being declared, so
recursive records work:

```lua
record List
    v: integer
    next: List?
end
```

The `next` field uses an [option type](option-types.md) so that a list
can end: a field of plain type `List` could never be `nil`, and you could
never construct the first cell. (But see the
[limitation on option-typed records](#records-and-nil) below before
reaching for this pattern.)

*Limitation:* a field type that mentions a record declared *later* in
the module — including mutually recursive records — passes the type
checker but does not build: the generated C refers to the later record's
type tag before it is declared, and the C compiler rejects it. Only
self-references work; order declarations so field types only mention
records already declared.

## Records are nominal

Two record types are distinct types if they come from distinct
declarations — even when their fields are identical:

```lua
record Celsius
    degrees: float
end

record Fahrenheit
    degrees: float
end

function freeze(c: Celsius): Fahrenheit
    local t: Fahrenheit = c   -- compile-time error
    return t
end
```

```
test.titan:10:11: type error: types in declaration of local variable t
do not match, expected test.Fahrenheit but found test.Celsius
```

The full name of a record type is *module*.*RecordName* (`test.Point`,
`geometry.Point`, ...), and that is the entire identity: two records are
the same type exactly when they are the same declaration in the same
module. This holds at run time too — passing the wrong record across the
Lua boundary is a run-time error that names both types:

```
test.titan:1:1: type error, expected test.Rec but found test.Point
```

Nominal typing is also a hard wall for the `value` type's compatibility
rules: while `{value}` is compatible with `{float}`, compatibility never
recurses *into* a record — a record with `value` fields is not
interchangeable with a record with `float` fields (see
[the type system](types.md)).

## Creating records

### `RecName.new`

Every record automatically gets a static function `new` with one
parameter per field, in declaration order:

```lua
local p = Point.new(2.0, 3.0)   -- p: Point, with x = 2.0 and y = 3.0
```

Arity is strict, as for all Titan calls — `Point.new(1)` is a
compile-time error
(`function 'Point.new' called with 1 arguments but expects 2.`,
followed by the expected signature).
Each argument gets the usual implicit coercions of a function argument,
so `Point.new(2, 3)` fills the `float` fields with `2.0` and `3.0`.

`new` is not magic: the compiler synthesizes it as a static function
whose body is a record constructor expression over its parameters.

### Constructor expressions

A record can also be built with a constructor expression listing every
field by name:

```lua
local p: Point = { x = 2.0, y = 3.0 }
```

Constructor expressions are only valid where the context already expects
a specific record type — the expression itself does not say which record
it builds. Record-expecting contexts are: declarations and module
variables annotated with the record type, assignments to record-typed
variables and fields, arguments to record-typed parameters, `return` in
a function declared to return the record, fields of an enclosing record
constructor, and elements of array or map constructors whose element
type is the record. Without such a context the constructor is a
compile-time error (`no context to provide type for record constructor`).

*Limitation:* some of those contexts are accepted by the checker but
broken in the code generator. A constructor expression as the right-hand
side of a single-assignment *statement* whose target is a module variable
(`g = { ... }` inside a function), a record field (`o.i = { ... }`), or
a local that is never read anywhere in the function (the code generator
elides never-read locals) aborts `titanc` with an internal compiler
error (a Lua error reading
`Internal compiler error: missing template variable TMPNAME`, followed
by a traceback) — no C is produced. Assignments to locals that are read,
and to array or map elements, work; a *multiple* assignment
(`g, n = { ... }, 0`) goes through a temporary and works even for module
variables and record fields; and `RecName.new(...)` works for every
target.

The field list is checked strictly, all at compile time:

* every entry must name a field — `{ x = 1.0, z = 2.0 }` gives
  `field 'z' not found in record type 'test.Point'`;
* every field must be present — omitting `y` gives
  `field 'y' from record type 'test.Point' missing in constructor`;
* entries must be named, never positional — `{ 1.0, 2.0 }` gives
  `missing field in initializer for record type 'test.Point'`;
* each value must match (or coerce to) the field's type, with the usual
  `expected float but found string` style of message.

### Records in module variables

A module variable can hold a record, and both constructor forms are
accepted as its (constant) initializer:

```lua
p: Point = { x = 1.0, y = 2.0 }
origin: Point = Point.new(0.0, 0.0)
```

Both initializer forms compile and work at run time. *Reassigning* the
variable from inside a function is another matter: `Point.new(...)`
works, but a constructor expression hits the compiler crash described
[above](#constructor-expressions):

```lua
function recenter()
    p = Point.new(30.0, 40.0)    -- fine
    p = { x = 30.0, y = 40.0 }   -- internal compiler error
end
```

The record declaration must appear *before* a module variable of its
type — a record constructor in an initializer that precedes the `record`
declaration is a compile-time error. Function bodies and signatures have
no such ordering requirement.

## Fields

Fields are read and written with `.`, exactly like Lua table fields:

```lua
function flip(p: Point)
    local t: float = p.x
    p.x = p.y
    p.y = t
end
```

Reading a field the record does not have, or writing to one, is a
compile-time error (`field 'z' not found in record 'test.Point'`).
Assignments must match the field's declared type, with the same implicit
coercions as any assignment.

A record is a *reference* value: assigning it to another variable,
passing it to a function, or storing it in an array, map, module
variable, `value`, or another record copies the reference, never the
contents; mutations through one reference are visible through all.

Record fields can themselves have record types, and nesting works as
expected:

```lua
record Inner
    v: integer
end

record Outer
    i: Inner
end

function make(): Outer
    return { i = { v = 1 } }    -- nested constructor: context is the field type
end

function bump(o: Outer)
    o.i.v = o.i.v + 1
end
```

## Methods

Methods are declared at the top level with Lua's colon syntax, naming the
record they belong to, and called with the colon as well:

```lua
record Point
    x: float
    y: float
end

function Point:move(dx: float, dy: float)
    self.x = self.x + dx
    self.y = self.y + dy
end

function demo()
    local p = Point.new(1.0, 2.0)
    p:move(1.0, 1.0)
end
```

Inside a method, `self` is implicitly declared with the record's type
and is not listed among the parameters. (The compiler does not reject a
parameter *named* `self`; declaring one merely shadows the implicit
receiver.) Method calls are
resolved *statically* — there are no virtual tables, so the compiler
knows exactly which function `p:move(...)` calls.

Rules and their compile-time errors:

* The `record` declaration must come earlier in the file than its
  methods (`record referenced by method declaration 'Point:getx' does
  not exist`), and the name before the colon must actually be a record
  (`member referenced by method declaration ... is not a record`).
* A method may not share a name with a field
  (`cannot declare method 'Foo:foo' as field 'foo' exists in record 'Foo'`)
  and may not be declared twice (`redeclaration of method 'Point:foo'`).
* Calling a missing method: `method 'm' not found in record 'test.R'`.
  Calling a method on something that is not a record:
  `expected record in receiver of method call but found 'integer'`.

**Methods are not fields.** In Titan code a method name can only be used
in a call; `p.move` as a value, or `p.move = ...`, is the compile-time
error `field 'move' not found in record 'test.Point'`. (Functions are not
first-class values in this version of Titan — see
[Functions](functions.md).)

## Static functions

`new` is currently the *only* static function a record has. There is no
syntax for declaring your own — `function Point.origin() ... end` is a
syntax error in the current grammar. If you need a custom constructor,
write a module function:

```lua
function origin(): Point
    return Point.new(0.0, 0.0)
end
```

Accessing a static the record does not have is a compile-time error
(`trying to access invalid record function 'nope'`), and the record type
itself is not a value — `return Point` gives
`trying to access record type 'test.Point' as a first-class value`.

## Records across modules

A record declared in one module is usable from any module that
[imports](modules.md) it: the qualified name works in type position, and
`new`, constructor expressions, fields, and methods all work normally:

```lua
-- geometry.titan
record Point
    x: float
    y: float
end

function Point:norm2(): float
    return self.x * self.x + self.y * self.y
end
```

```lua
-- client.titan
local geo = import "geometry"

function origin_distance2(): float
    local p: geo.Point = geo.Point.new(3.0, 4.0)
    return p:norm2()
end
```

Record identity is global per type, not per loaded copy: records of the
same type created by different modules — or by the same module loaded
both statically and as a shared library — share one metatable and pass
each other's type checks. Same-*named* records from different modules
remain different types (`geometry.Point` is not `test.Point`).

## Records from Lua

To Lua, a Titan record is a **userdata** (not a table) with full access
to its fields and methods:

```lua
-- Titan (module test)
record Point
    x: float
    y: float
end

function Point:move(dx: float, dy: float)
    self.x = self.x + dx
    self.y = self.y + dy
end
```

```lua
-- Lua
local test = require "test"

local p = test.Point.new(1, 2)   -- record types live in the module table
print(type(p))                   --> userdata
p:move(1.0, 1.0)                 -- methods work with Lua's colon call
print(p.x, p.y)                  --> 2.0  3.0
p.x = 10.0                       -- field writes are type-checked
```

The details, all run-time behavior:

* **Construction.** Each record name is an entry in the module table
  holding its statics, so `test.Point.new(1, 2)` works from Lua. Arity
  is checked at run time:
  `calling Titan function new with 1 arguments, but expected 2`.
* **Field reads and writes** go through the record's metatable and are
  fully checked. An unknown field, read or written, raises
  `field 'z' not found in record 'test.Point'`; a wrongly-typed write
  raises `type error, expected float but found string`. Lua code can
  never put an ill-typed value into a record.
* **Methods** can be read (`p.move` is a callable value in Lua) and
  called with `p:move(...)`; `self` is type-checked like any record
  argument. Methods cannot be *assigned*: `p.move = 2` raises the same
  "field ... not found" error — method names are not fields.
* **Identity.** A record instance is one stable userdata: sending the
  same record to Lua twice (or round-tripping it through Lua, an array,
  or a `value`) yields the same object, and mutations on either side are
  visible on both. Two separately constructed records are different
  objects (`p1 ~= p2`); `==` on records is identity, in Lua and in
  Titan alike.
* **The metatable is protected.** `getmetatable(p)` returns the string
  `"Titan record test.Point"`, and Lua code cannot replace or reach the
  real metatable. Combined with the checks above, Lua can inspect and
  mutate records but never corrupt them — at worst it gets a run-time
  error (catchable with `pcall`, see [error handling](error-handling.md)).

## Records and nil

The option type `Point?` exists and can be used in signatures, fields
(as in the `List` example), and locals; nil-ness is tested by truthiness
(`if p then ... end`), and option records can be passed along and
returned freely.

*Limitation:* the current compiler cannot **unwrap** an option-typed
record. Any construct that needs the `Point` out of a `Point?` — reading
a field (`p.x`), assigning it to a plain `Point` variable, or letting an
unannotated `local` force it — makes code generation fail with an
internal compiler error, and calling a method through an option receiver
is rejected by the checker (`expected record in receiver of method call
but found 'test.Point?'`). An option record as a `while` condition also
fails to build — the generated C does not compile — though `if`
conditions and `not` work. Indexing an array of records (`a[1].x`) is
unaffected. Until this is fixed, treat `Point?` as
pass-through-and-test-only. See [option types](option-types.md) for the
general machinery.

## What records are not

* **Not tables.** You cannot index a record with brackets, take its
  length (`#p` is the compile-time error `trying to take the length of
  a test.Point instead of an array or string`), or iterate its fields.
  From Lua it is a userdata, not a table.
* **No metatables of your own.** The metatable is fixed, generated by
  the compiler, and protected; there is no operator overloading and no
  `__eq`/`__tostring`/`__index` customization.
* **No inheritance.** No subtyping between record types, no method
  overriding; method dispatch is fully static. Records were designed as
  a deliberate stepping stone toward possible classes later, not as a
  class system.
* **Not first-class.** Neither the record type nor its methods can be
  used as values, in this version of Titan.

## Performance notes

A record value is pointer-sized; its fields live in a fixed-size vector
of slots owned by the record, so `p.x` is a constant-offset load and
`p.x = v` a constant-offset store — no hashing, no string comparison, no
metamethod dispatch. Method calls compile to direct C function calls.
Constructing a record allocates two small heap objects (the field
vector and its Lua-facing wrapper), both managed by Lua's garbage
collector like every other Titan value.

*Implementation note:* the dual representation (a `CClosure` of slots
for Titan, a tagged userdata for Lua, pointing at each other) and the
type-tag scheme behind the nominal run-time checks are described in
[values and GC](../implementation/values-and-gc.md) and
[Lua interop internals](../implementation/lua-interop-internals.md).
