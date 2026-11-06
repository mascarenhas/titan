# Records

Records are Titan's structured data type: named, fixed-shape values with
a declared set of typed fields, plus methods. They are the moral
equivalent of structs — the compiler knows each field location, so reading
`p.x` uses direct access rather than a hash lookup. Like Arrays but unlike Maps,
records are **not** Lua tables at the Lua boundary; they are userdata.
Records are a distinct kind of value with their own identity, and they are typed
*nominally* — by which declaration they come from, not by what fields
they happen to have.

## Declaring a record

A record declaration may only appear at the top level of a module. Each
field is `[local] [const] name: type`; fields are separated by newlines or
semicolons (a trailing semicolon is fine):

```titan
record Point
    const id: integer
    x: float
    y: float
end
```

A const field is filled during record construction and cannot be replaced
later. Put optionality on the field type, as in
`local const cache: Cache?`; `cache?: Cache` is not field syntax. Constness is shallow: a const field containing a
mutable container or record retains that object's ordinary mutability. See
[Const values](const-values.md#const-record-fields).

Declaring the same field twice is a compile-time error
(`redeclaration of field 'x' in record 'Point'`).

An empty record (`record Empty end`) is legal: it can be constructed
with `Empty.new()` and crosses to Lua like any other record, though with
no fields or methods there is little you can do with one.

By default a record is exported: its name becomes a member of the module,
both for importing Titan modules and for Lua (see below). A record declared
with `local record` is module-local instead:

```lua
local record Cell
    value: integer
    next: Cell?
end
```

A local record type can be used freely inside the defining module, including in
local functions and local variables, but it is not a module member and cannot be
named by importers. It also cannot appear anywhere in the public type surface:
exported functions, methods, module variables, type aliases, or public record
fields, because compiled module interfaces only serialize the public surface.

Field, method, and record-function names are contextual, so a keyword such as
`end` is a valid member name. Public keyword-named members are available to
importing modules, including when only the compiled provider is present.

A record's field types may mention the record being declared, so
recursive records work:

```titan
record List
    v: integer
    next: List?
end
```

The `next` field uses an [option type](option-types.md) so that a list
can end: a field of plain type `List` could never be `nil`, and you could
never construct the first cell. Walking such a list reads the `next`
field as a plain `List`, which [unwraps](#records-and-nil) the option
with a run-time nil check.

A field type may also mention a record declared *later* in the module,
or a [union](unions.md) declared later, and mutually recursive nominal
definitions work as well:

```lua
record Tree
    value: integer
    branch: Branch?
end

record Branch
    left: Tree
    right: Tree
end
```

The written `record` declaration does not have to precede its uses. Records are
known throughout their module before record functions, methods, signatures,
and module-variable declarations are checked. Consequently a method or record
function may appear before its record, and a module variable may use either
`Rec.new(...)` or a context-typed constructor expression before the written
record declaration:

```titan
origin: Point = Point.new(0.0, 0.0)

function Point:is_origin(): boolean
    return self.x == 0.0 and self.y == 0.0
end

record Point
    x: float
    y: float
end
```

This module-wide visibility is independent of field order: the parameters of
the synthesized `new` function and the logical field indices still follow
the order written inside the `record` declaration.

Record fields and union parts support ordinary Titan values, foreign scalars
and pointers, and eligible complete C structs, C unions, and fixed C arrays.
Fixed C objects are copied into their owner and project borrowed interior
pointers on access. Native foreign numbers keep their exact C values until an
actual conversion boundary. See [Native storage in records and
unions](nominal-storage.md) for eligibility, shallow constness, pointer
lifetimes, and fresh buffer construction.

## Records are nominal

Two record types are distinct types if they come from distinct
declarations — even when their fields are identical:

```titan
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

Nominal typing is also a hard wall for gradual consistency:
while `{value}` is consistent with `{float}`, consistency never
recurses *into* a record — a record with `value` fields is not
interchangeable with a record with `float` fields (see
[the type system](types.md)).

## Creating records

### Calling a record

A record reference in call position selects its `new` function. Positional,
named, and single-string calls are shorthand for the corresponding calls to
`new`:

```text
Point(2.0, 3.0)                  -- Point.new(2.0, 3.0)
Point { y = 4.0, x = 1.0 }       -- Point.new { y = 4.0, x = 1.0 }
Label "hello"                   -- Label.new "hello"
```

The shorthand works with imported records and record aliases, preserves the
constructor's visibility and complete result list, and uses ordinary call
adjustment. Named expressions evaluate in written order. It does not make the
record namespace a first-class Titan value: save `Point.new` when a callable
value is needed. Prefer the shorthand when creating records.

Explicit owner arguments use `Box<|integer|>(item)`, equivalent to
`Box<|integer|>.new(item)`. If an override also has callable-local generic
parameters, the ordinary rule requiring both explicit lists or neither still
applies; write `Box<|integer|>.new<|string|>(item)` when both lists are needed.

### Default `new`

Unless overridden, every record automatically gets a static function `new` with one
parameter per field, in declaration order:

```lua
local p = Point.new(2.0, 3.0)   -- p: Point, with x = 2.0 and y = 3.0
local q = Point.new { y = 4.0, x = 1.0 }
```

Like any Titan function call, `Point.new` pads omitted arguments with
`nil` and then type-checks them against the corresponding field type.
That means `Point.new(1)` is accepted only when the second field can
accept `nil`; for a required `float` field it is a compile-time type
error (`expected float but found nil`). Surplus positional expressions are
evaluated and ignored, like those of every fixed-parameter Titan function.
Each argument used by `new` gets the usual function-argument adjustment, so
`Point.new(2, 3)` fills the `float` fields with `2.0` and `3.0`. As a record
static declaration, `new` also supports
[named-call syntax](named-arguments.md): fields may be written in any order,
and any omitted parameter receives the same checked `nil` fill.

`new` is not magic: the compiler synthesizes it as a record function
whose body is a record constructor expression over its parameters. For a local
record, `new` is local too. For an exported record with any local field, `new`
is also local, because exposing it would let outside code supply private field
values through its parameters.

### Overriding `new`

Declare a record function named `new` to replace the generated constructor:

```titan
record Counter
    local amount: integer
end

function Counter.new(initial: integer?): Counter
    local amount = initial or 0
    if amount < 0 then raise "negative initial count" end
    return { amount = amount }
end
```

The declaration may precede or follow the record, including in another file of
the same folder module. It is an ordinary record function: its parameters,
parameter names, generic parameters, variadic input, and result list are its
own. It may be public even when the record has private fields, or explicitly
`local` even when all fields are public. Calls through the record name obey
that visibility too.

An override need not return the record, or even one result:

```titan
record Parsed end

function Parsed.new(input: string): (integer, string)
    return #input, input
end

function parse_example(): (integer, string)
    return Parsed "hello"
end
```

The generated `new` no longer exists; calling `Counter(...)` or
`Counter.new(...)` inside the override recurses. Use a context-typed `{ ... }`
expression to allocate the raw record. Once `new` is overridden, those raw
constructor expressions are allowed **only in the defining module**, even if
the override and all fields are public. Explicit source imports do not grant
this construction privilege. Importers must call the visible `new` or use the
record-call shorthand.

### Constructor expressions

A record can also be built with a constructor expression listing fields by
name:

```titan
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

A constructor expression works in every one of those contexts. In
particular, assigning one as the right-hand side of a single-assignment
*statement* — to a module variable (`g = { ... }` inside a function), a
record field (`o.i = { ... }`), or a local — behaves exactly like the
initializer form, just as `RecName.new(...)` does.

Construction initializes mutable and const fields alike. These field stores
are initialization operations, not ordinary assignments, so they do not
create a post-construction write path for const fields.

The field list is checked at compile time:

* every entry must name a field — `{ x = 1.0, z = 2.0 }` gives
  `field 'z' not found in record type 'test.Point'`;
* an omitted field is filled with `nil` only when `nil` has an assignment
  adjustment to its type (for example `T?`, `value`, `boolean`, or a nullable
  pointer);
  otherwise the compiler reports that the field cannot be omitted because its
  type does not accept nil;
* entries must be named, never positional — `{ 1.0, 2.0 }` gives
  `missing field in initializer for record type 'test.Point'`;
* each value must have an assignment adjustment to the field's type (identity,
  direct coercion, gradual view/projection, or callable adjustment), with the
  usual `expected float but found string` style of message;
* if an explicit field is repeated, both values are evaluated and stored in
  source order, so the final entry wins. Named *calls*, by contrast, reject a
  repeated argument name.

This makes partial and empty constructors useful when all omitted slots are
nil-compatible:

```titan
record Config
    label: string?
    enabled: boolean
    payload: value
end

local defaults: Config = {}
local labelled: Config = { label = "test" }
```

Constructor expressions require access to every field. An ordinary import of
a record with local fields therefore rejects raw construction, even `{}` and
even when every private field could accept `nil`. Inside the defining module,
public and local fields use the same omission rule; explicit source
collaboration may also expose private fields. A `new` override imposes the
stricter defining-module-only rule regardless of field visibility, so even a
source collaborator must call the constructor.

### Records in module variables

A module variable can hold a record. A raw constructor expression or a call
to the default generated constructor can initialize it:

```titan
p: Point = { x = 1.0, y = 2.0 }
origin: Point = Point(0.0, 0.0)
```

Both initializer forms compile and work at run time. *Reassigning* the
variable from inside a function works the same way, with either form:

```lua
function recenter()
    p = Point.new(30.0, 40.0)
    p = { x = 30.0, y = 40.0 }
end
```

An own-module overridden `new` is an own-function dependency and cannot be used
in a module-variable initializer. An imported custom `new` is permitted because
its module is already initialized. Every evaluated operand still follows the
[initializer dependency rule](modules.md#initializer-dependencies), including
implicit calls used to compute an argument. When an initializer stores a
lambda or another own callable through an imported generated constructor, the
compiled consumer also requires that constructor to remain generated. Only
values delivered to the constructor's parameters create that requirement, not
surplus arguments or spread elements that no parameter receives; see
[Replacing shared-library
dependencies](binary-compatibility.md#private-record-fields-and-construction).
Use the module's final `do ... end` block for initialization that needs
own-module state or callables.

The record declaration may appear before or after the module variable. The
module-variable ordering restriction concerns only imports and other module
variables: an imported record used directly by a module-variable declaration
must come from an earlier import. See
[Declaration order and visibility](modules.md#declaration-order-and-visibility).

## Fields

Fields are read and written with `.`, exactly like Lua table fields:

```titan
function flip(p: Point)
    local t: float = p.x
    p.x = p.y
    p.y = t
end
```

Reading a field the record does not have, or writing to one, is a
compile-time error (`field 'z' not found in record 'test.Point'`).
Assignments use the same assignment adjustments as any other typed target and
must be accepted at the field's declared type. A const field can be read but
not assigned after construction.

A record is a *reference* value: assigning it to another variable,
passing it to a function, or storing it in an array, map, module
variable, `value`, or another record copies the reference, never the
contents; mutations through one reference are visible through all.

Record fields may also have **function types** and hold function values:
a field typed as a function can store a top-level function, a lambda, an
imported module's function, a record's `new` static, or a
[bound method reference](#methods) (`obj:m`), and the stored value can be
called through the field.

Record fields can themselves have record types, and nesting works as
expected:

```titan
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

### Local fields

A field may be prefixed with `local`:

```titan
record Box
    local hidden: integer
    shown: integer
end
```

Local fields are real fields, but only code in the defining
module may read or write them. Importing Titan modules and Lua code see only the
public fields; attempting to read or write a hidden field reports the same
"field not found" error as an absent field.

## Methods

Methods are declared at the top level with Lua's colon syntax, naming the
record they belong to, and called with the colon as well:

```titan
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

Prefixing a method declaration with `local` makes the method callable only in
the defining module:

```titan
local function Box:secret(): integer
    return self.hidden
end
```

Local methods are not serialized into compiled module interfaces and are not
installed in the Lua record metatable. Outside the module, they behave like
missing methods.

Inside a method, `self` is implicitly declared with the record's type
and is not listed among the parameters. (The compiler does not reject a
parameter *named* `self`; declaring one merely shadows the implicit
receiver.) Method calls are
resolved *statically* — there are no virtual tables, so the compiler
knows exactly which function `p:move(...)` calls.

Rules and their compile-time errors:

* The `record` declaration may come before or after its methods. The name
  before the colon must name a record declared somewhere in the module; if no
  such record exists the compiler reports `record referenced by method
  declaration 'Point:getx' does not exist`, and if the name denotes a
  non-record member it reports `member referenced by method declaration ...
  is not a record`.
* A method may not share a name with a field
  (`cannot declare method 'Foo:foo' as field 'foo' exists in record 'Foo'`)
  and may not be declared twice (`redeclaration of method 'Point:foo'`).
* Calling a missing method: `method 'm' not found in record 'test.R'`.
  Calling a method on something that is not a record:
  `expected record in receiver of method call but found 'integer'`.

**Methods are not fields.** In Titan code a method name can only be used
after a colon; `p.move` as a value, or `p.move = ...`, is the compile-time
error `field 'move' not found in record 'test.Point'`. Method names are
not fields.

**Bound method references.** A method *named but not called*, `p:move`
with no argument list, **is** a first-class value: a *bound method
reference* whose type is the method's type with the implicit `self`
removed, with the receiver `p` bound in. The receiver is evaluated once,
when the reference is taken, and the result is an ordinary function value —
store it, pass it, return it, call it, or hand it to Lua:

```titan
function demo(): integer
    local p = Point.new(1.0, 2.0)
    local m: function (float, float): () = p:move   -- bound to p
    m(1.0, 1.0)                              -- runs Point:move on p
    return 1
end
```

The receiver is captured by reference, so a bound method that mutates the
record is visible through it. Bound references work across modules, including
dependencies recovered from compiled `.so` or `.a` providers. The full rules,
errors and examples are in
[anonymous functions and closures](closures.md#bound-method-references).

## Records and Interfaces

A record does not declare that it implements an
[Interface](interfaces.md). Instead, a statically known conversion site checks
the record's required fields and methods structurally. Every required
Interface field needs a visible, same-name const record field whose type can be
automatically assignment-adjusted to the required type. Every required method
must be visible at that site and satisfy the Interface signature under
directional callable adjustment. Record functions do not count.

Visibility is therefore intentional. A `local` method can satisfy an Interface
for a conversion inside its defining module, but cannot satisfy the same
Interface for an importing module that cannot see that method. Parameter
spellings do not participate in satisfaction; named calls through the wrapper
use the Interface declaration's names.

An accepted `R -> I` conversion constructs a fresh Interface wrapper retaining
the record and shallowly snapshotting its required fields. It is one direct
coercion, not inheritance, subtyping, or gradual
consistency, and it does not lift through Arrays, Maps, Options except for the
named option plans, or Functions. Direct calls on an `R` remain statically
dispatched; calls through an `I` dispatch through the wrapper selected at
conversion time. Each conversion is fresh, so two wrappers around the same
record are not equal.

## Record functions

A record function is declared at top level with a dot-qualified record name:

```titan
function Point.origin(): Point
    return Point.new(0.0, 0.0)
end
```

Like a method, a record function may be written before or after the record
declaration it belongs to.

Record functions are called as `RecName.func(...)`. They have no implicit
`self` parameter; use a method (`function RecName:m(...)`) when the function
operates on a receiver. A record function may be declared `local`, in which
case it is visible only inside the defining module:

```titan
local function Point.checked(x: float, y: float): Point
    return Point.new(x, y)
end
```

For a generic record, explicit owner arguments attach to the record namespace:
`Box<|integer|>.new(1)`. A record function with its own parameters keeps those
after the member name, as in `Box<|integer|>.convert<|string|>(text)`. If both owner
and callable-local scopes are open, write both complete lists or neither; see
[Generics](generics.md#explicit-type-arguments).

Methods and record functions may declare input-variadic parameters and
flexible result tails exactly like module functions. A bound method reference
preserves both tails after binding `self`; the synthesized `new` constructor
itself remains a fixed-result function returning one record.

The synthesized `new` constructor is just a record function. When its default
visibility is local because the record has local fields, a public override can
expose a controlled factory:

```lua
record Cell
    local generation: integer
    value: integer
end

function Cell.new(value: integer): Cell
    return { generation = 0, value = value }
end
```

Accessing a function the record does not have is a compile-time error
(`trying to access invalid record function 'nope'`), and the record type
itself is not a value — `return Point` gives
`trying to access record type 'test.Point' as a first-class value`.

`Rec.func` itself is a first-class value, exactly like a
top-level function: it can be passed as an argument, stored in a variable,
array, map, or record field, returned, and called indirectly, not just
written inline as `Rec.func(...)`. If the record function is local, that
first-class value is available only inside the defining module.

## Records across modules

An exported record declared in one module is usable from any module that
[imports](modules.md) it: the qualified name works in type position, and public
fields, public methods, and public record functions work normally:

```titan
-- geometry.titan
record Point
    x: float
    y: float
end

function Point:norm2(): float
    return self.x * self.x + self.y * self.y
end
```

```titan
-- client.titan
local geo = import "geometry"

function origin_distance2(): float
    local p: geo.Point = geo.Point.new(3.0, 4.0)
    return p:norm2()
end
```

Local records and local record members are omitted from the imported interface.
If an exported record has local fields, importers can still receive and pass
values of that record type and access its public fields, methods, and record
functions. Its default `new` is private, and outside raw `{ ... }` construction
is unavailable. The defining module may expose a public `new` override or
another factory when outside code needs instances. A public override can be
called as `Rec(...)` or `Rec.new(...)`; it keeps raw construction inside the
defining module even for records with no private fields.

Imported unions follow this exact visibility frontier. Their types,
constructors, methods, and union functions are available to signatures and
bodies independent of import placement; direct qualified uses in a
module-variable initializer, including inside an evaluated lambda, still see
only earlier imports. See [Unions](unions.md#visibility-and-declaration-order).

Record identity is global per type, not per loaded copy: records of the
same type created by different modules — or by the same module loaded
both statically and as a shared library — share one metatable and pass
each other's type checks. Same-*named* records from different modules
remain different types (`geometry.Point` is not `test.Point`).

## Records from Lua

To Lua, a Titan record is a **userdata** (not a table) with access to its public
fields and public methods:

```titan
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

local p = test.Point(1, 2)       -- record namespaces are callable when new is public
print(type(p))                   --> userdata
p:move(1.0, 1.0)                 -- methods work with Lua's colon call
print(p.x, p.y)                  --> 2.0  3.0
p.x = 10.0                       -- field writes are type-checked
```

The details, all run-time behavior:

* **Construction and record functions.** Each record name is a member of the
  module — a small namespace table holding its public record functions — so
  `test.Point(1, 2)`, `test.Point.new(1, 2)`, and `test.Point.origin()` work from
  Lua when the corresponding functions are public. A namespace with public
  `new` has a `__call` metamethod that calls its `new` member without passing
  the namespace as an argument, preserving every result. Missing Lua arguments
  are padded with `nil` and checked against the declared parameter types;
  surplus arguments to a fixed-parameter function are ignored. Lua brace calls
  still pass one table argument: Titan's named-call syntax is compile-time
  syntax and does not add named Lua arguments.
* **Field reads and mutable-field writes** go through the record's metatable
  and are fully checked. An unknown field, read or written, raises
  `field 'z' not found in record 'test.Point'`; a wrongly-typed write
  raises `type error, expected float but found string`. A write to a const
  field raises a const-write error. Lua code can never replace a const field
  or put an ill-typed value into a mutable field.
* **Methods** can be read (`p.move` is a callable value in Lua) and
  called with `p:move(...)`; `self` is type-checked like any record
  argument. Methods cannot be *assigned*: `p.move = 2` raises the same
  "field ... not found" error — method names are not fields.
* **Local records and members** are hidden from Lua. A local record is not a
  member of the module value. Local fields and methods on an exported record
  raise "field ... not found" when Lua tries to read or write them. Local
  record functions, including a local `new`, are absent from the record
  namespace table, and a namespace whose `new` is local has no `__call`.
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
(`if p then ... end`, and also as a `while` condition), and option
records can be passed along and returned freely.

Wherever a bare `Point` is required, a `Point?` is **unwrapped** with a
run-time nil check: reading a field (`p.x`), calling a method (`p:move()`),
assigning it to a plain `Point` variable, and letting an unannotated
`local` force it all work, raising a clean `expected test.Point but found
nil` error if the value is `nil` at run time. See
[option types](option-types.md) for the general machinery.

## What records are not

* **Not tables.** You cannot index a record with brackets, take its
  length (`#p` is the compile-time error `trying to take the length of
  a test.Point instead of an array or string`), or iterate its fields.
  From Lua it is a userdata, not a table.
* **No metatables of your own.** The metatable is fixed, generated by
  the compiler, and protected; there is no operator overloading and no
  `__eq`/`__tostring`/`__index` customization.
* **No inheritance.** No subtyping between record types, no method
  overriding; direct record-method dispatch is fully static. Interface
  conversion is explicit wrapper construction at a typed edge, not a base
  class relation.
* **The record type itself is not a value.** A record type cannot be used
  as a value — `return Point` is an error. Its `new` static, by contrast,
  *is* a first-class value, like any top-level function, and an instance
  method can be taken as a value through a
  [bound reference](#methods) (`obj:method`).
* **Not a tagged union.** Records always have their declared field set. Use a
  [union](unions.md) when a value has one of several named alternatives and
  inspect it with `case`.

## Performance notes

A record value is pointer-sized; its fields live in a fixed-size vector
of slots owned by the record, so `p.x` is a constant-offset load and
`p.x = v` a constant-offset store — no hashing, no string comparison, no
metamethod dispatch. Method calls compile to direct C function calls.
Constructing a record allocates **one** small heap object — a tagged Lua
userdata holding the fields — managed by Lua's garbage collector like
every other Titan value.

*Implementation note:* a record value *is* a single tagged userdata
(`type(rec) == "userdata"`) — the same object Titan computes with and
Lua sees, with no separate wrapper. That representation and the type-tag
scheme behind the nominal run-time checks are described in
[values and GC](../implementation/values-and-gc.md) and
[Lua interop internals](../implementation/lua-interop-internals.md).
