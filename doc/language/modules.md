# Modules

A Titan source file with the `.titan` extension is a *Titan module* —
the unit of compilation, of namespacing, and of distribution. A module
compiles to a native shared library that Lua programs load with
`require` and other Titan modules use with `import`; a module that
defines a [`main` function](functions.md) becomes a standalone
executable instead. This chapter describes what goes inside a module
file, how modules reference each other, and what the compiler produces.

## What a module is made of

The top level of a module is a sequence of *declarations* — there are
no top-level statements. A declaration is one of:

* an **import**: `local m = import "modname"`;
* a **foreign import**: `local h = foreign import "header.h"` (see
  [the C FFI](ffi.md));
* a **module variable** declaration: `[local] name [: type] = exp`;
* a **function** declaration: `[local] function name(...) ... end`;
* a **record** declaration: `record Name ... end` (see
  [Records](records.md));
* a **method** declaration: `function Name:method(...) ... end`, also
  covered in [Records](records.md).

```lua
-- Titan: a small but complete module (shapes.titan)
record Circle                     -- record
    radius: float
end

unit: Circle = { radius = 1.0 }   -- exported module variable
local two_pi = 6.283185307179586  -- local module variable

function circumference(c: Circle): float   -- exported function
    return two_pi * c.radius
end

local function check(c: Circle): boolean   -- local function
    return c.radius > 0.0
end
```

Because every top-level `name = exp` is a declaration, writing the same
name twice at the top level is not an assignment but a duplicate
declaration — a compile-time error — and the rule holds across kinds: a
function may not share a name with a module variable or an import.

```lua
-- Titan
x = 1
x = 2   -- error: duplicate declaration for x, previous one at line 1
```

## Declaration order and visibility

Declarations may appear in any order, and the compiler conceptually
reorders them: imports come first (in the order written), then records,
then module variables (in the order written), then functions.
Concretely, the rules are:

* **Function and method bodies are order-independent.** A body may
  refer to any import, module variable, record type, or function in the
  module, including ones declared further down the file. (The compiler
  collects all top-level signatures in a first pass and only then
  checks bodies.)

  ```lua
  -- Titan: forward references from bodies are fine
  function get(): integer
      return x + later()
  end

  x = 10

  local function later(): integer
      return x * 2
  end
  ```

* **Top-level declarations themselves are checked in source order.** A
  module-variable declaration can only mention imports and record types
  that appear *above* it in the file; referring to one declared below
  is a compile-time error (`module '...' referenced by type not found`,
  or `record type '...' in context of record constructor does not
  exist`). In practice: imports first, then records, then variables.

* **Initialization order is fixed.** When a module is loaded into a Lua
  state (the first `require` from Lua, or transitively as a dependency
  of another module), its imported modules are initialized first, then
  its record types, then its module variables in declaration order, and
  finally its exported functions are published. A module initializes at
  most once per Lua state; subsequent loads return the same module.

## Module variables

A module-variable declaration has the form

```lua
-- Titan
[local] <name> [: <type>] = <expression>
```

The type annotation is optional; without it the type is inferred from
the initializer. With an annotation, the usual
[implicit coercions](types.md) apply, so `pi: float = 3` declares a
float-typed variable holding `3.0`.

A `local` variable is visible only inside its module. A variable
without `local` is *exported*: modules that import this one can read
and write it through their import alias, and Lua code that `require`s
the module can read and write it as a member of the module value (which
is a userdata; writes from Lua are type-checked at run time — see
[Module variables from Lua](lua-interop.md#module-variables-from-lua)).

### Initializers must be constant

The initializer of a module variable must be a compile-time constant
expression. The allowed forms are:

* `nil`, boolean, integer, float, and string literals;
* array, map, and record [constructor expressions](expressions.md)
  whose elements, keys, values, and fields are themselves constant;
* calls to a record's `new` constructor with constant arguments;
* concatenations, unary operators, binary operators, and `as` casts
  applied to constant operands.

Anything else — in particular any variable reference and any other
function call — is rejected with the compile-time error
`top level variable initialization must be constant`; a variable that
needs a computed initial value must start from a constant placeholder
and be assigned from a function at run time.

```lua
-- Titan
x = 10
y = x + 1          -- error: top level variable initialization must be constant
s = "a" .. "b"     -- ok: constant expression
n = -(2 * 3)       -- ok: constant expression
```

Record constructors are accepted by this rule, so
`p: Point = { x = 1.0, y = 2.0 }` and `p = Point.new(1.0, 2.0)` both
work as module-variable declarations, at compile time and at run time.
*Reassigning* such a variable with a constructor expression from inside
a function works the same way — `p = { x = 30.0, y = 40.0 }` as a
statement is equivalent to the initializer form. See
[Records in module variables](records.md#records-in-module-variables).

## Importing other modules

An `import` declaration makes another Titan module's exported members
available under a local alias:

```lua
-- Titan
local <localname> = import "<modname>"
```

The module name is given as a string literal, with single or double
quotes; the parenthesized form `import("<modname>")` is also accepted.
The alias is always `local` — imports are never re-exported, so there
is no way to reach module `c` through `b` from `a` (`a.b.c`-style
nesting does not exist).

A module name is a dot-separated name like `foo`, `foo.bar`, or
`foo.bar.baz`, mapped to a file path by turning dots into directory
separators: module `foo.bar` lives in `foo/bar.titan` (source) or
`foo/bar.so` (compiled) — see
[Where modules are found](#where-modules-are-found) below.

Through the alias, the importing module can use everything the imported
module exports:

```lua
-- Titan: geom/point.titan
record Point
    x: float
    y: float
end

origin: Point = { x = 0.0, y = 0.0 }

function norm(p: Point): float
    return (p.x * p.x + p.y * p.y) ^ 0.5
end
```

```lua
-- Titan: main.titan
local geom = import "geom.point"

function f(): float
    local p = geom.Point.new(3.0, 4.0)  -- imported record's constructor
    return geom.norm(p)                 -- imported function
end

o: geom.Point = { x = 1.0, y = 1.0 }    -- imported record as a type

function g(): float
    geom.origin.x = 0.0                 -- imported variable, writable
    return geom.norm(o)
end
```

Exported variables of the imported module can be both read and
assigned (`geom.origin.x = 0.0` above); writes from Titan are
statically checked and compile to direct stores, with no run-time type
check. Record types are referenced as `alias.Name` in type annotations,
and their constructors and static functions as `alias.Name.new(...)`.

An exported function is itself a **first-class value**: besides calling it
as `geom.norm(p)`, the importer can reference `geom.norm` as a value — pass
it, store it, return it, and call it indirectly — with stable identity (the
same function reference each time) and a fast call path. (Only the function
is first-class; the module alias itself is not, as described next.)

Modules are not first-class values: the alias can only be used as a
prefix. Reading it as a value (`local m2 = geom`) is the compile-time
error `trying to access module 'geom' as a first-class value`;
assigning to it is `trying to assign to a module`. Importing the same
module under two aliases is allowed; both denote the same instance.

**Circular imports are a compile-time error.** If `a` imports `b` and
`b` imports `a` (directly or through a longer chain), compilation fails
with `problem loading module 'a': circular reference to module`,
reported at the `import` declaration that closes the cycle.

## Why `import` is not `require`

The first design of the module system used Lua's own idiom,
`local foo = require "foo"`. It was renamed `import` after a design
debate (pull requests #40 and #44) that produced one of the project's
guiding rules, stated by Hisham Muhammad:

> "I am really concerned about constructs that have identical syntax to
> Lua but different semantics, especially since we expect programmers
> to hop back and forth between the two languages. ... I really think
> that different semantics should be visually distinguishable in the
> source code."

The semantics really are different: Lua's `require` is dynamic — it
runs at run time, returns a first-class value, and resolves the module
by searching paths at that moment. Titan's `import` is static — the
imported module's interface is resolved and typechecked at compile
time, the alias is a compile-time namespace rather than a value, and
the dependency is (by default) compiled in. In the words of the same
discussion: "`require` is our analogue to `dlopen`, while the static
import is more like `#include`/`-l`. ... Let's just call it `import`,
make it an evident keyword, and make a clear distinction between the
static `import` and the dynamic `require`."

There is consequently no way to `require` a Lua module from Titan code
today: `import` loads Titan modules and `foreign import` loads C
headers (see [the C FFI](ffi.md)); calling into Lua is a roadmap item
(see [Lua interoperability](lua-interop.md#calling-lua-from-titan)).

## Compiling modules: `titanc`

The compiler driver is invoked with dot-separated *module names*, not
file paths:

```sh
./titanc [--print-ast] [-v] [--lua <luasrc>] [--tree <srcroot>] [-l lib1,lib2] <module>...
```

* `--tree <srcroot>` sets the source tree root (default `.`); module
  `foo.bar` is looked up at `<srcroot>/foo/bar.titan`.
* `--lua <luasrc>` points at the Lua source tree the generated C is
  built against (default `lua-5.5.0/src`).
* `-l/--link` adds extra C libraries to the link line (FFI use).
* `-v/--verbose` prints the C compiler command lines; `--print-ast`
  dumps the parsed AST.

`titanc` first typechecks every requested module and every transitive
dependency, reports *all* errors, and exits with status 1 before
generating any code if any module failed. Only when everything checks
does it compile and link.

Compilation goes through C: each module becomes one C translation unit,
written next to its source, and the system C compiler (`cc`, with
`--std=c99 -O2 -Wall -fPIC`) does the rest. For module `foo.bar` the
generated artifacts are:

| Artifact | What it is |
| --- | --- |
| `foo/bar.c` | the generated C, next to the source |
| `foo/bar.o` | the compiled object file |
| `foo/bar.so` | the shared library (when there is no `main`) |
| `foo/bar` | the executable (when `foo.bar` defines `main`) |
| `foo/bar__entrypoint.c` | the generated C `main` for executables |

The `.c` and `.o` are written next to the `.titan` source; the linked
`.so`, the executable, and the entrypoint `.c` are written to the
`foo/bar` path relative to the directory `titanc` runs in — the same
place only when compiling from the root of the source tree (the
`--tree` default).

The driver also maintains `titan-runtime/titan.o`, a small support
library rebuilt automatically when out of date.

*Implementation note:* the driver and the exact compiler invocations
are described in [the driver documentation](../implementation/driver.md);
the structure of the generated C is in
[the code generator overview](../implementation/codegen-overview.md).

## Where modules are found

* **Source modules** are looked up in the *source tree* — the directory
  given by `--tree`, defaulting to the current directory. Generated
  `.c`/`.o` files are always written next to the source; the linked
  `.so` lands relative to the compiler's working directory, as
  described above.
* **Compiled modules** are looked up along the *binary search path*: a
  semicolon-separated list of directories taken from the environment
  variable `TITAN_PATH_0_5`, or `TITAN_PATH` if that is unset,
  defaulting to `.;/usr/local/lib/titan/0.5` — a list of plain
  directories, not a Lua-style template path. The same path is used at
  run time by compiled modules that load dependencies dynamically.

Lua's `require`, for its part, finds the `.so` through Lua's ordinary
`package.cpath` — a compiled Titan module is a regular Lua C module
(see [Requiring a Titan module](lua-interop.md#requiring-a-titan-module)).

## Static and dynamic linking

The linking policy (set by pull request #237) is *static when source is
available, dynamic otherwise*:

* If an imported module's `.titan` source can be found in the source
  tree, it is compiled and **statically linked** into the artifact
  being built. Building `main` from the example above with
  `./titanc main` compiles `geom/point.titan` too and produces a
  `main.so` that contains both modules — there is nothing else to
  deploy, and cross-module calls are direct C calls.
* If only a compiled `.so` is found, the compiler recovers the module's
  interface from type information embedded in the library, and the
  generated code **dlopens** the dependency at run time, finding it on
  the binary search path. This is what makes distributing binary-only
  Titan modules possible.

A statically linked dependency is still a module of its own from Lua's
point of view: if `main.so` embeds `geom.point` and a Lua script also
`require`s `geom.point`, both refer to the same module instance in that
Lua state, with the same record types and the same module variables.

## Standalone executables

If exactly one of the modules given to `titanc` defines a function with
the exact signature

```lua
-- Titan
function main(args: {string}): integer
```

the output is a standalone executable instead of shared libraries (the
declared return type must literally be `integer`). All requested
modules and all dependencies with source are statically bundled into
the binary — no dynamic loading of Titan modules is involved. `args` is
Lua-style: `args[0]` is the program name and `args[1]` onward are the
arguments, so `#args` is the argument count. The integer returned by
`main` becomes the process exit status; an uncaught run-time error
prints an error message (with no traceback) to standard error and exits
with a failure status (see [Error handling](error-handling.md)).

```lua
-- Titan: hello.titan
function main(args: {string}): integer
    return #args
end
```

```sh
$ ./titanc hello
$ ./hello a b ; echo $?
2
```

If more than one requested module defines `main`, compilation fails
with `<module>: multiple main functions found (already declared in
<other module>)`. The `main` convention is described further in
[Functions](functions.md).

## Running with a stock Lua

Compiled Titan modules and executables run against an unmodified Lua —
no patched interpreter, no custom build flags beyond compiling the Lua
sources with `-fPIC`. Each compiled module statically embeds the parts
of the Lua core it uses (the build links `liblua.a` into every `.so`
and executable), which is why the compiler needs a built Lua source
tree and not just an installed interpreter. This was a deliberate
packaging decision (pull request #231), together with the removal of
global C state from generated modules (#233/#235): a Titan module keeps
all of its state per Lua state, so the same module can be loaded into
several Lua states in one process, each with its own copies of the
module variables — see
[Multiple Lua states](lua-interop.md#multiple-lua-states). Each
compiler release does target one specific Lua version (currently
Lua 5.5), because the generated code works against that version's
internals.
