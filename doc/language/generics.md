# Generics

Titan supports explicit, invariant parametric polymorphism on nominal types (records, unions, and Interfaces) and named callables. A generic declaration is type-checked once against its type parameters and compiled into a single erased native implementation—there is no monomorphization and no runtime type-argument object. At each call or construction site, Titan infers or checks a complete list of type arguments and enforces representation safety at the boundaries.

```titan
record Pair<|T, U|>
    first: T
    second: U
end

union Result<|T, E|>
    ok(T)
    err(E)
end

function foldl<|T, U|>(
    items: const? { T },
    combine: function (U, T): (U),
    initial: U
): U
    local acc = initial
    for i = 1, #items do
        acc = combine(acc, items[i])
    end
    return acc
end

function total_lengths(words: const? { string }): integer
    return foldl(words, function (acc, word) return acc + #word end, 0)
end

function make_pair(): Pair<|integer, string|>
    return Pair(1, "one")
end
```

## Declaring type parameters

A nonempty type-parameter list delimited by `<|` and `|>` immediately follows the declared name:

```text
<|T, U|>
<|T, R: io.Reader|>
```

Using `<|` and `|>` keeps type lists syntactically unambiguous with `<` and `>` comparisons, and nested applications such as `Outer<|Inner<|T|>|>` need no space between closing delimiters.

Type parameters may appear on:

- `record`, `union`, and `interface` declarations;
- top-level and `local` module functions;
- record and union methods and static functions; and
- Interface methods.

Type aliases, anonymous functions (lambdas), and `foreign function` declarations cannot declare their own type parameters, though a lambda inside a generic body may refer to the enclosing parameters. A generic function named `main` is an ordinary library function rather than a standalone executable entry point.

A parameter list allows up to 100 parameters with no trailing comma, no duplicate names, and no cyclic constraints. All parameter names in a list are visible when resolving that list's constraints.

### Owner and callable scopes

A generic record, union, or Interface brings its type parameters into scope across all of its fields, variants, methods, and static functions. Method and static-function definitions keep the owner name bare and may add their own callable-local parameters:

```titan
record Pair<|T, U|>
    first: T
    second: U
end

function Pair:map_first<|V|>(transform: function (T): (V)): Pair<|V, U|>
    return Pair(transform(self.first), self.second)
end

function Pair.replace_first<|V|>(pair: Pair<|T, U|>, item: V): Pair<|V, U|>
    return Pair(item, pair.second)
end
```

Write `function Pair:map_first<|V|>`, never `function Pair<|T, U|>:map_first<|V|>`. Inside `Pair:map_first`, the implicit `self` has type `Pair<|T, U|>`. A callable-local parameter cannot shadow an owner parameter of the same name.

## Interface constraints

A type parameter may be constrained by a visible Interface application written after `:`:

```titan
local io = import "io"
local strings = import "string"

function read_all<|R: io.Reader|>(source: R): string
    local out = strings.writer()
    for chunk in source:read do
        out:write(chunk)
    end
    return out:drain()
end

function demo_read(): string
    local reader = strings.reader("hello generics")
    return read_all(reader)
end
```

A type argument satisfies constraint `I` when it is:

1. that exact applied Interface `I`;
2. a visible record or union that structurally satisfies `I` at the call or application site (wrapped automatically via Titan's standard [Interface conversion](interfaces.md)); or
3. another in-scope type parameter with the same applied Interface constraint.

Inside the generic body, a value of a constrained type parameter exposes only the Interface's declared read-only fields and methods—never extra members of a concrete implementer. Distinct Interface constraints do not satisfy one another structurally.

```titan
interface Container<|E|>
    function get(): E
end

record Box<|E|>
    item: E
end

function Box:get(): E
    return self.item
end

function unwrap_container<|T, C: Container<|T|>|>(box: C): T
    return box:get()
end

function use_box(): string
    return unwrap_container(Box("titan"))
end
```

When an Interface declares a generic method, an implementing method must have the same number of callable-local parameters, matching constraints (up to parameter renaming), and a compatible signature under directional callable adjustment.

## Applying generic types

Generic records, unions, and Interfaces are applied with a complete argument list matching the owner's arity:

```text
Pair<|integer, string|>
Result<|{string}, string|>
Pair<|T, U|>?
{Pair<|T, U|>}
```

`<|...|>` binds more tightly than `?`, so `Pair<|T, U|>?` is an option of `Pair<|T, U|>`.

### Invariance

Applied generic types are **invariant**: `Box<|integer|>` and `Box<|float|>` are distinct, non-convertible types, and `Box<|Buf|>` does not convert to `Box<|io.Reader|>` even when `Buf` satisfies `io.Reader`.

For an unconstrained parameter, gradual consistency relates a concrete application to its `value` view (`Box<|integer|>` is consistent with `Box<|value|>`). For a constrained parameter `T: I`, the corresponding erased view uses the erased Interface constraint rather than `value`.

### Bare generic names mean all-`value`

In an ordinary type position, writing a generic owner without type arguments fills every parameter with `value`:

```titan
record Pair<|T, U|>
    first: T
    second: U
end

function loose_pair(): Pair
    -- Pair means Pair<|value, value|>
    return Pair<|value, value|>(1, "one")
end
```

Bare spelling is legal only when `value` satisfies every owner constraint; a constrained owner such as `Holder<|R: io.Reader|>` requires explicit type arguments.

### Forwarding type aliases

Although `type` aliases cannot declare their own type parameters, an alias whose right-hand side is a bare generic owner forwards that owner's type parameters and static namespace:

```titan
record Pair<|T, U|>
    first: T
    second: U
end

type Tuple2 = Pair
type IntPair = Pair<|integer, integer|>

function alias_examples(): (Tuple2<|string, integer|>, IntPair)
    local a = Tuple2<|string, integer|>("ok", 200)
    local b = IntPair(1, 2)
    return a, b
end
```

`Tuple2<|A, B|>` is identical to `Pair<|A, B|>`, while `IntPair` is already closed and takes no further type arguments.

## Type-argument inference and explicit arguments

At every generic call or constructor, Titan determines a complete set of type arguments locally in this priority order:

1. an explicit complete `<|...|>` list;
2. owner arguments already fixed by the method receiver;
3. expected result types from the surrounding context, left to right; and
4. arguments in written evaluation order (positional left-to-right, named arguments in written order, and generic-`for` tuple inputs before loop-variable annotations).

Once a parameter is determined by the first piece of evidence that reaches it, later arguments are checked against that chosen type under normal assignment rules rather than triggering a common-supertype search:

```titan
function pick_first<|T|>(left: T, right: T): T
    return left
end

function inference_order(): (integer, float)
    local a = pick_first(1, 2.0)   -- T = integer; 2.0 narrows to 2
    local b = pick_first(1.0, 2)   -- T = float; 2 widens to 2.0
    return a, b
end
```

Expected-result context takes effect before argument expressions: `local x: float = pick_first(1, 2)` selects `T = float` and promotes both integer arguments to `float`. Expressions that need surrounding context—untyped lambdas, contextual `value` calls, `{}` constructors, and record literals—wait for sibling evidence in the same call before resolving. Passing an optional value such as `({string: integer})?` to a non-optional structural parameter `{K: V}` (such as `iteration.pairs`) infers `K = string` and `V = integer` while keeping the runtime nil check.

### Unresolved parameters close to their carrier

When no argument or expected return type constrains a parameter—common for empty union variants or result-only constructors such as `async.channel<|T|>()`—the parameter closes to its erased carrier (`value` if unconstrained, or its Interface constraint if constrained):

```titan
local async = import "async"

function demo_channels()
    local send, recv, close_ch = async.channel<|string|>(1) -- string channel
    send("ping")
    local msg = recv()
    close_ch()

    local any_send, any_recv, any_close = async.channel(1)  -- T closes to value
    any_send(msg)
    any_recv()
    any_close()
end
```

Provide either an explicit `<|...|>` list or an expected target type whenever a result-only parameter should resolve to a concrete type.

### Explicit type arguments

Explicit type-argument lists are all-or-none—there is no partial explicit list:

```titan
record Box<|T|>
    item: T
end

function Box:convert<|U|>(f: function (T): (U)): Box<|U|>
    return Box(f(self.item))
end

function Box.from<|U|>(src: U, f: function (U): (T)): Box<|T|>
    return Box(f(src))
end

function explicit_examples(): (Box<|integer|>, Box<|string|>)
    local boxed = Box<|integer|>(42)
    local text = boxed:convert<|string|>(function (n) return "" .. n end)
    local built = Box<|integer|>.from<|string|>("7", function (s) return #s end)
    return built, text
end
```

Placement rules:

- **Top-level function:** `foldl<|integer, string|>(...)` (also works with named calls: `make<|integer|> { item = 1 }`).
- **Method on a receiver:** supply only callable-local arguments (`boxed:convert<|string|>(...)`), because the receiver already fixed the owner arguments.
- **Record/union constructor or static:** owner arguments attach to the owner (`Box<|integer|>(42)`, `Result<|integer, string|>.ok(1)`). If a static function also declares its own parameters, supply both lists or neither.

### Generic functions as first-class values

A generic declaration is not a polymorphic value at run time; referencing it as a value instantiates it immediately. An expected function type selects its type arguments, while an unannotated reference closes them to their erased carriers:

```titan
function id<|T|>(x: T): T
    return x
end

function as_values(): (integer, value)
    local int_id: function (integer): (integer) = id
    local any_id = id                               -- function (value): (value)
    return int_id(7), any_id("ok")
end
```

Explicitly owner-applied constructors (`Box<|integer|>.new`) must be called directly; to take a constructor as a function value, use the bare name with an expected function type (`local make: function (integer): (Box<|integer|>) = Box.new`).

## Rigid parameters and eligible type arguments

Inside a generic body, type parameters are **rigid**—the body must type-check for every valid instantiation, not for one specific concrete type.

An unconstrained parameter `T` supports:

- passing, returning, assigning, and storing values of type `T`;
- optional `T?`, Arrays `{T}`, Maps `{K: T}` and `{T: V}`;
- equality (`==`, `~=`) with `T`, `nil`, and `value`;
- conversion to and from `value`, and explicit `as`/`is` checks against its erased carrier.

`T` does not support arithmetic, ordering (`<`), concatenation (`..`), `#`, indexing, calling, field access, or truthiness conditions unless constrained by an Interface or explicitly cast.

### Eligible type arguments

Every type argument (explicit or inferred) must have a canonical GC-safe representation that can be boxed into its erased carrier and strictly checked on the way back out:

- **Eligible:** `nil`, `boolean`, `integer`, `float`, `string`, `value`, `T?`, Arrays, Maps, Titan functions, records, unions, Interfaces, in-scope type parameters, C numeric scalars (checked on boxing/unboxing), `owned` C storage, and C `TValue` (provided all nested components are also eligible).
- **Ineligible:** raw C pointers (`foreign *T`), C arrays, C functions and function pointers, `void`, and plain C structs/unions—whether directly or nested inside an Option, container, callback, or unused type parameter.

## Type erasure, runtime checks, and Lua

Titan compiles one body for each generic declaration by erasing every unconstrained parameter `T` to `value` and every constrained parameter `T: I` to `I`.

- **Shared runtime identity:** `Box<|integer|>` and `Box<|string|>` share one runtime record identity. They cannot be assigned to each other statically, though `==` may compare them for object identity.
- **Forward boxing, strict reverse checks:** Values passing *into* generic code are boxed or wrapped directly. Values coming *out* of generic code to a concrete type undergo a strict runtime type check at the first concrete use (such as arithmetic, field access, or assignment to a typed variable).
- **Delayed failure on raw writes:** Because unconstrained generic fields erase to `value`, writing a `value` directly into a generic field succeeds and defers detection until typed code reads it at a concrete type:

```titan
record Cell<|T|>
    item: T
end

function overwrite<|T|>(cell: Cell<|T|>, raw: value)
    cell.item = raw
end

function delayed_check(): integer
    local cell = Cell(1)      -- Cell<|integer|>
    overwrite(cell, "wrong")  -- stores raw value; succeeds here
    return cell.item          -- raises at run time: expected integer, found string
end
```

For a constrained parameter `T: I`, storing a `value` checks the `value -> I` Interface boundary immediately.

- **Shallow casts and containers:** `raw as Box<|integer|>` and `raw is Box<|integer|>` verify only the outer `Box` record identity, never its type arguments or current field contents. Do not rely on phantom type parameters for runtime security across `value` or Lua boundaries. An Array created inside generic code with unconstrained element `T` uses the permissive `{value}` Lua writer while retaining strict reads when viewed as `{integer}`.
- **Callbacks:** Passing a concrete function into a generic parameter (such as the lambda passed to `foldl`) automatically adapts arguments and results across the erased boundary; closure identity is not preserved across such adapted boundaries.
- **From Lua:** Lua has no type-argument syntax and always sees the erased declaration—unconstrained parameters and fields behave as `value`, constrained ones expect the erased Interface, and non-generic parameters and fields keep their ordinary Lua boundary checks.

### Optional Arrays and Maps

Use the instantiated type of a generic result or field just as you would a
non-generic value. For example, an inferred local forces a `{integer}?`
result, an optional local keeps nil, and passing a `{integer}` to a
`{integer}?` parameter wraps it. None of these steps copies the Array or Map,
and typed reads still check individual elements.

```titan
local function keep<|T|>(items: {T}?): {T}?
    return items
end

function first(items: {integer}?): integer
    local present = keep<|integer|>(items)
    return present[1]
end
```

The same rules apply to the values delivered by a flexible result tail. If
a variadic parameter requires a non-optional Array or Map, each delivered
Option is forced before forwarding, even when the generic function stores its
arguments as `value`. When the offered value is dynamically represented, it
must be nil or have the required outer container kind before the force; nil
then fails the force. Element checks still wait until typed reads, and a
`value` flow without a required container force is unchanged.

An ordinary assignment from `{value}?` to `{integer}` still requires a
separate structural view and Option force.

A nil generic Array or integer-keyed Map used as a spread subject raises
before the spread bounds are evaluated. The error names the instantiated
container, for example `expected { integer } but found nil`.
