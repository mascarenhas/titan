# Modules

A *Titan module* is the unit of compilation, namespacing, and distribution.
Its source may be one flat `.titan` file or a canonical main plus immediate
`.titan` contributors in a [folder module](folder-modules.md). Both forms
compile as one logical module. In library mode, one or more related logical
modules are linked into a physical provider DSO/archive pair and receive
generated Lua loaders; Lua programs use `require` and other Titan modules use
`import` without exposing that physical grouping. A module that defines a
[`main` function](functions.md) becomes a standalone executable instead. This
chapter describes what goes inside a logical module, how modules reference
each other, and what the compiler produces. See
[Multi-module libraries](multi-module-libraries.md) for the provider and
loader rules.

## What a module is made of

The top level of a module is a sequence of *declarations*, optionally followed
by one root `do ... end` [module initialization block](#module-initialization-block).
A declaration is one of:

* an **import**: `local m = import "modname"`;
* a **foreign import**: `local h = foreign import "header.h"` (see
  [the C FFI](ffi.md));
* a **module variable** declaration: `[local] name [: type] = exp` or
  `[local] const name [: type] [= exp]`;
* a **function** declaration: `[local] function name(...) ... end`;
* a **type alias** declaration: `[local] type Name = type` (see
  [Type aliases](type-aliases.md));
* a **record** declaration: `record Name ... end` (see
  [Records](records.md));
* a **union** declaration: `union Name ... end` (see
  [Unions](unions.md));
* an **Interface** declaration: `interface Name ... end` (see
  [Interfaces](interfaces.md));
* a **method** declaration: `function Name:method(...) ... end`, also
  covered in [Records](records.md) and [Unions](unions.md).

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
function may not share a name with a module variable or an import. Type aliases
and Interfaces use the separate type-only namespace: they may share a spelling
with those value declarations, but not with another alias, record, union, or
Interface.

```lua
-- Titan
x = 1
x = 2   -- error: duplicate declaration for x, previous one at example.titan:1:1
```

## Declaration order and visibility

Most declarations may appear in any order. A flat module's logical order is
its file order; a folder module's deterministic combined order is main
declarations first, then contributors in numeric-byte basename order, then the
main initializer
([Folder modules](folder-modules.md#declaration-order)). Visibility is broader
than that sequence, with one deliberate frontier for module variables:

* **Records, unions, Interfaces, type aliases, and callable declarations are
  order-independent.**
  A nominal type, ordinary function, method, or nominal function may be declared
  before or after any of the others. Signatures, Interface field and method
  signatures, record fields, union
  payloads, and alias targets may use nominal types, aliases, and imports
  declared later in the logical
  order. Synthesized record and union constructors are likewise available
  throughout the module, so construction may precede the written owner
  declaration.

* **Function and method bodies are order-independent.** A body may refer to
  any import, module variable, nominal type, ordinary function, method, or
  nominal function in the module, including ones declared later or in another
  contributor.

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

* **A module-variable declaration sees only earlier imports and module
  variables.** Imports and foreign imports are processed in logical order, but
  their aliases are available regardless of placement to every declaration
  other than a module variable. At each module-variable declaration, its type
  annotation and initializer see only import aliases and module variables that
  occur earlier in the logical order. They still see every record, union,
  Interface, type alias, ordinary function, method, nominal function, and
  synthesized constructor, wherever those declarations occur. This visibility
  does not make a non-constant
  initializer legal; the separate [constant-expression
  rule](#initializers-must-be-constant) still applies.

  ```lua
  -- Titan
  origin: Point = Point.new(0.0, 0.0) -- ok: Point may be declared later

  record Point
      x: float
      y: float
  end

  imported: geometry.Point? = nil     -- error: geometry is not visible yet
  local geometry = import "geometry"
  ```

  The same earlier-import frontier applies to a qualified record/union
  constructor use nested in a lambda evaluated by the initializer. A type
  alias may still bridge to a later import because aliases are resolved in the
  placement-independent type frontier.

* **Visibility does not reorder the module.** The logical order still decides
  which declaration is earlier in a duplicate diagnostic, orders serialized
  interface members and run-time module slots, fixes the relative
  initialization order of module variables, and remains the order used for
  code generation.

* **Initialization order is fixed.** When a module is loaded into a Lua
  state (the first `require` from Lua, or transitively as a dependency
  of another module), its imported modules are initialized first, then
  its record, union, and Interface identities and concrete/Interface pair
  vtables, then its module variables in declaration order, and
  finally its exported functions are published and its optional initialization
  block runs. A module initializes at most once per Lua state; subsequent loads
  return the same module.

## Module initialization block

After its declarations, a module may have one root `do ... end` block for
computed initialization that cannot be expressed by constant module-variable
initializers:

```lua
local ready: boolean = false

local function prepare()
    -- ...
end

do
    prepare()
    ready = true
end
```

This block must be the final root construct and runs once per Lua state, after
the module's declarations have been initialized. In a folder module it may
appear only in the canonical main source; the compiler places it after every
contributor declaration. It may call contributor-local functions because all
files share one module scope. Ordinary nested `do` statements remain legal in
every source file.

The block is also the sole assignment region for an initializer-less const
module variable owned by this logical module. Permission follows this root
function frame through nested blocks, but does not flow into a function or
lambda called or created from it. An explicit source import does not grant an
importer's initializer authority over the producer's const slots.

## Module variables

A module-variable declaration has the form

```lua
-- Titan
[local] <name> [: <type>] = <expression>
[local] const <name> [: <type>] [= <expression>]
```

The type annotation is optional when an initializer is present; without it the
type is inferred from the initializer. With an annotation, the usual
[assignment adjustments](types.md#relations-and-boundaries-no-subtyping)
apply, so `pi: float = 3` declares a float-typed variable holding `3.0`.

An initialized const module variable is never assignable. A const declaration
may omit its initializer only with an explicit type that admits the missing nil
representation; the slot starts as nil/NULL and can be assigned only while code
executes directly in its owning root module initializer. Nested callables and
other modules' initializers do not inherit that permission. The owner
initializer may assign it conditionally or repeatedly; it becomes read-only
when initialization finishes. See
[Const values](const-values.md#const-module-variables).

A `local` variable is hidden from the public module interface; it is available
inside its owner and through a qualified [explicit source collaboration
import](source-import-visibility.md). A variable without `local` is *exported*:
modules that import this one can read it through their import alias, and can
write it when it is mutable. Lua code that `require`s the module likewise sees
it as a member of the module value; mutable writes are type-checked at run time
and const writes are rejected — see
[Module variables from Lua](lua-interop.md#module-variables-from-lua)).

### Initializers must be constant

The initializer of a module variable must be a compile-time constant
expression. The allowed forms are:

* `nil`, boolean, integer, float, and string literals;
* array, map, and record [constructor expressions](expressions.md)
  whose elements, keys, values, and fields are themselves constant;
* calls to a record's `new` constructor with constant arguments;
* calls to a compiler-synthesized union-variant constructor with a constant
  payload, or no payload for an empty variant;
* calls to an imported C type's `.new()` or `.new_array(count)` pseudo-
  constructor, with a constant `count`;
* concatenations, unary operators, binary operators, `as` casts, and `is`
  type tests applied to constant operands.

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
work as module-variable declarations. Owned C constructors work as well, for
example `local state = c.State.new()` or
`local slots = c.Slot.new_array(4)`. The constructors run once when that module
instance initializes; the resulting objects are rooted in its GC-traced state.
*Reassigning* such a variable with a constructor expression from inside
a function works the same way — `p = { x = 30.0, y = 40.0 }` as a
statement is equivalent to the initializer form. See
[Records in module variables](records.md#records-in-module-variables).
Genuine generated union constructors are accepted for the same reason.
A user-written union function that happens to return a variant is still an
ordinary function call and is not constant.

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

An ordinary import exposes only exported members even when lookup happens to
select source. To intentionally require source and opt in to the imported
module's local collaboration interface, append the marker `.titan` inside the
string:

```titan
local internal = import "foo.bar.baz.titan"
```

This imports logical module `foo.bar.baz`; the suffix is not part of its name.
It searches for folder source `foo/bar/baz/baz.titan` and then flat source
`foo/bar/baz.titan` according to the ordinary source-root rules. If neither
source form exists, compilation fails even when a compiled provider claims
`foo.bar.baz`. See [Visibility through explicit source imports](source-import-visibility.md).

A module name is a dot-separated name like `foo`, `foo.bar`, or
`foo.bar.baz`, mapped to a path by turning dots into directory separators.
Each component begins with an ASCII letter or underscore and continues with
ASCII letters, digits, underscores, or hyphens. Hyphens are valid in the
logical and filesystem name; the native protocol mangles them to underscores
and rejects any resulting symbol-prefix collision. Characters such as `$`
are not module-name characters. A dotted logical name ending in the component
`titan`, such as `foo.titan`, is forbidden because that terminal spelling in an
import is always the explicit-source marker for `foo`. The bare logical module
`titan` and a nonterminal component such as `foo.titan.child` remain valid.
Module `foo.bar` lives in flat source `foo/bar.titan`, folder source with main
`foo/bar/bar.titan`, or a compiled provider whose metadata claims `foo.bar` — see
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

Exported mutable variables of the imported module can be both read and
assigned (`geom.origin.x = 0.0` above); writes from Titan are statically
checked and compile to direct stores, with no run-time type check. Exported
const variables are readable but not assignable. Exported record and union
declarations serve two roles: their types are
referenced as `alias.Name` in annotations, and their run-time nominal
functions as `alias.Name.new(...)`, `alias.Name.make(...)`, or a union variant
constructor. An exported type alias to a record or union preserves both roles:
`alias.Name` is valid as a type, and Titan resolves
`alias.Name.new(...)`, public record/union functions, and public union variant
constructors directly to the original nominal owner. This does not add a
run-time member or a second namespace to the re-exporting module, and it does
not make any local constructor or function public.

An exported Interface is type-only. Importers may write `alias.Name` in a type
position and may convert visible satisfying records or unions to it, but
`alias.Name` is not a run-time namespace or first-class member. Interface
identity and method metadata are nevertheless part of the compiled module
contract so wrappers constructed in another module use the owner module's
canonical per-state Interface identity.

An exported function is itself a **first-class value**: besides calling it
as `geom.norm(p)`, the importer can reference `geom.norm` as a value — pass
it, store it, return it, and call it indirectly — with stable **source**
identity (the same exact function reference each time) and a fast call path. An
admitted non-exact target-typed use may subsequently realize a fresh
[closure adjustment wrapper](closure-adjustment-wrappers.md); that wrapper
does not replace the canonical imported source. (Only the function is
first-class; the module alias itself is not, as described next.)
Its imported static type preserves both input-variadic and flexible-result
tails, so calls through a source or compiled-module interface use the same
finite projection and open-run rules as local calls.

Imported public record and union statics are first-class with the same stable
identity. Their canonical closures are part of the reconstructible
public module-state prefix: exported variables, exported top-level function
closures, then public nominal static closures in module-member and bytewise
static-name order. Variants remain metadata and are not first-class types.

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
the dependency is selected from source or from a compiled module at compile
time. In the words of the same
discussion: "`require` is our analogue to `dlopen`, while the static
import is more like `#include`/`-l`. ... Let's just call it `import`,
make it an evident keyword, and make a clear distinction between the
static `import` and the dynamic `require`."

Ordinary Titan dependencies therefore use `import`, while `foreign import`
loads C headers (see [the C FFI](ffi.md)). When run-time Lua/Titan/C-module
discovery is the actual requirement, the [`titan.lua` standard
module](standard-library-lua.md) exposes a deliberately dynamic
`lua.require(name): value` escape hatch. It does not create a static namespace
or replace `import`; isolate the returned `value` and recover a precise Titan
type at that boundary. Lua callables can also enter Titan as function-typed
values — for example, as an argument from Lua — and Titan can call them
normally (see [Lua interoperability](lua-interop.md#calling-lua-from-titan)).

## Compiling modules: `titanc`

The compiler driver is invoked with dot-separated *module names*, not
file paths:

```sh
titanc [--print-ast] [--pretty-print] [-v] [-j jobs] [--static] [--test] \
  [--no-uv-bootstrap] [--no-line-directives] [--lua <luasrc>] \
  [--tree <srcroot>] [-l lib1,lib2] [-X object...] <module>...
```

* `--tree <srcroot>` sets the source tree root (default `.`); module
  `foo.bar` is looked up first at the folder main
  `<srcroot>/foo/bar/bar.titan`, then at flat source
  `<srcroot>/foo/bar.titan`.
* `--lua <luasrc>` points a source-checkout compiler at a complete Lua
  source/build tree. Checkout developer mode otherwise uses
  `lua-5.5.1/src`. An installed compiler rejects this override and always
  uses its matched `<root>/src/lua-5.5.1` headers,
  `<root>/lib/liblua.a`, and `<root>/lib/titan/0.6/libtitan.a`.
* `-l/--link` adds extra C libraries to the link line (FFI use).
* `-j/--jobs <jobs>` bounds concurrent generated-C object compilations. It
  defaults to the positive integer in `TITAN_JOBS`, or to `1` when that
  variable is unset. Values above one require the standard POSIX `mkfifo`
  utility. Parsing, checking, C generation, generated-header work, and final
  linking remain ordered in the compiler process.
* `--static` prefers self-describing Titan `.a` providers over `.so`
  providers for ordinary dependencies. It still permits DSO/source fallback
  and does not request a fully static system executable.
* `--test` source-prefers the requested roots' complete dependency graph,
  discovers public `test_*` functions, and links a standalone native test
  executable even without an application `main`. See
  [Testing Titan code](standard-library-test.md).
* `--no-uv-bootstrap` is valid only when the result is a normal standalone
  executable or a `--test` executable. The generated entrypoint still
  initializes every imported module and preserves the installed bootstrap
  registry value, but calls `main(args)` directly instead of invoking that
  value. This is an explicit lifecycle-ownership option, not a way to disable
  `titan.uv` initialization.
* `--no-line-directives` omits Titan source `#line` directives from generated
  C, so native compiler and sanitizer diagnostics use physical generated-C
  coordinates. By default diagnostics are attributed to Titan source.
  `TITAN_NO_LINE_DIRECTIVES=1` selects the same policy for build automation.
  This diagnostic mode can omit native Titan functions from logical
  tracebacks or render a boundary as `[C]`; do not use it for normal builds or
  traceback validation.
* `-X/--extra-object` adds native object/archive payload. Library mode carries
  it into both provider forms; executable mode uses it at final link.
* `--pretty-print` runs `clang-format` on generated C and source-foreign
  headers. Formatting is opt-in; without it Titan preserves the generator's raw
  layout while still removing blank physical lines after `#line` directives.
* `-v/--verbose` prints every C tool command line and, with `--pretty-print`,
  the formatter command line; `--print-ast` dumps the parsed AST.

`titanc` first typechecks every requested module and every transitive
dependency, reports *all* errors, and exits with status 1 before
generating any code if any module failed. Only when everything checks
does it compile and link.

`clang-format` is needed only for `--pretty-print`; `CLANG_FORMAT` selects a
different compatible command. In that mode Titan formats every generated `.c`
in place before invoking the C compiler and every generated `.titan.h` before a
compiler check consumes or publishes it. A formatter failure aborts native
compilation and provider publication. Default builds do not discover or invoke
a formatter.

Compilation goes through C: each logical module becomes one C translation
unit, written beside its canonical source, and the system C compiler (`cc`,
with `--std=c99 -O2 -Wall -fPIC`) does the rest. A single-root library build
uses that root as its physical provider:

| Source form for `foo.bar` | Generated C/object | Lua loader | Provider pair | Entrypoint | Executable |
| --- | --- | --- | --- | --- | --- |
| flat `foo/bar.titan` | `foo/bar.c`, `foo/bar.o` | `foo/bar.lua` | `foo/bar.so`, `foo/bar.a` | `foo/bar__entrypoint.c` | `foo/bar` |
| folder `foo/bar/bar.titan` | `foo/bar/bar.c`, `foo/bar/bar.o` | `foo/bar.lua` | `foo/bar.so`, `foo/bar.a` | `foo/bar__entrypoint.c` | `foo/bar__main` |

The Lua-loader and provider columns apply in library mode; the
entrypoint and executable columns apply in `main` program mode.

In `--test` mode the first requested root's executable column applies even when
no root declares `main`; the generated runner is the sole main. Its support,
runner, and entrypoint C/object files use `__test_support`, `__test_runner`, and
`__test_entrypoint` suffixes beside that executable stem. See the
[test chapter](standard-library-test.md#discovery-and-compilation).

With several no-`main` roots, Titan publishes one paired provider at their longest common
dotted-component prefix. For example, `titanc foo.left foo.right` produces
`foo.so` and `foo.a`, plus `foo/left.lua` and `foo/right.lua`; it does not
produce child providers. Roots without a common component are rejected. Every source dependency
linked into the provider also receives one logical Lua loader. The complete
grouping, lookup, ownership, and reserved-name rules are in
[Multi-module libraries](multi-module-libraries.md); archive precedence,
metadata, linking, and `--static` are in [Static compiled
modules](static-compiled-modules.md).

The provider pair, generated Lua loaders, executable, and entrypoint paths are
relative to the directory `titanc` runs in. Generated C and objects are beside
the flat source or folder main, even when `--tree` points elsewhere. A folder
contributor never produces a separate C file, object, loader, DSO, archive, or
executable. The folder program's `__main` suffix avoids colliding with its
source directory; the logical module name and entrypoint path remain
unchanged.

An installed compiler links `<root>/lib/titan/0.6/libtitan.a`; compiler development
directly from the repository lazily rebuilds and links
`titan-runtime/libtitan.a`. Both archives contain exactly `titan.o` and `minicoro.o`; source-defined
foreign callbacks live in their generated module objects, and neither driver
mode links `titan.o` directly. Vendored `libbacktrace.a` and the matching `liblua.a` remain separate
link inputs. The native Lua support entry is compiled from `ltitanlib.c`: a
private support-only bootstrap enables installation, while the canonical
installed provider pair carries that entry together with the standard logical
modules. Generated Lua loaders use its DSO form.

*Implementation note:* the driver and the exact compiler invocations
are described in [the driver documentation](../implementation/driver.md);
the structure of the generated C is in
[the code generator overview](../implementation/codegen-overview.md).

## Where modules are found

* **Source modules** are looked up in the *source tree* — the directory
  given by `--tree`, defaulting to the current directory. In each source root,
  the folder main `P/B.titan` wins over flat `P.titan`; a selected folder's
  immediate regular `.titan` siblings are assembled as contributors.
  Constituents are not directly importable as flat child modules, although a
  genuine deeper folder module remains legal. See
  [Folder modules](folder-modules.md#lookup-and-precedence) for the complete
  precedence and privacy rules. Generated
  `.c`/`.o` files are always written next to the source; the linked
  `.so`/`.a` provider pair lands relative to the compiler's working
  directory, as described above.
* **Compiled modules** are looked up along the *binary search path*: a
  semicolon-separated list of plain directories taken from
  `TITAN_PATH_0_6`, or `TITAN_PATH` if that is unset. Otherwise the default
  is `.;<root>/lib/titan/0.6`. An installed `titanc` recovers `<root>` from
  the first literal `package.cpath` entry ending in
  `/lib/lua/5.5/?.so`. For logical `a.b.c`, the default performs a complete
  pass over `a.so`, `a/b.so`, and exact `a/b/c.so`, then a complete pass over
  the corresponding `.a` paths; `--static` swaps those passes. A file in an
  earlier root shadows the same relative candidate in later roots within its
  format, while an unrelated ancestor container can advance to a deeper
  candidate. The same path is used at run time by dependencies selected from
  DSOs; a `;;` in an environment override inserts the default path. See
  [Finding a compiled module in a
  provider](multi-module-libraries.md#finding-a-compiled-module-in-a-provider)
  for DSO claims and [Static compiled
  modules](static-compiled-modules.md#dependency-search) for archive
  precedence and metadata.

Here `<root>` is the Titan SDK/rocks-tree root. `PREFIX` owns Lua and LuaRocks,
while `ROCKS_TREE` owns the Titan SDK and standard modules. The supported
developer installation currently makes those paths equal, which is why the
driver can discover the Titan root from Lua's `package.cpath`; the names do not
have inherently identical ownership.

The standard-library names `coroutine`, `uv`, `async`, `timer`, `io`, `fs`,
`net`, `ssl`, `url`, `http`, `os`, `peg`, `string`, `test`, `lua`, `math`, `gc`, and `iteration`
 are parser sugar for the qualified module names
`titan.coroutine`, `titan.uv`, `titan.async`, `titan.timer`, `titan.io`,
`titan.fs`, `titan.net`, `titan.ssl`, `titan.url`, `titan.http`, `titan.os`,
`titan.peg`, `titan.string`, `titan.test`, `titan.lua`, `titan.math`, `titan.gc`, and `titan.iteration`.

The qualified names then follow ordinary
module lookup rules. Thus
`local os = import "os"` means
Titan's `titan.os` module without colliding with Lua's own `os` library, which
is not importable as a Titan module. Likewise, `import "string"` selects
Titan's module without replacing Lua's `string` table.

The explicit-source marker is removed before this shorthand is expanded.
Consequently `import "uv.titan"` and `import "titan.uv.titan"` both require the
source for logical module `titan.uv`; neither spelling creates a module whose
name or manifest key ends in `.titan`.

Application scheduling uses `import "async"` (or Lua's
`require "titan.async"`). `titan.uv` is the private Runtime/libuv plumbing
module and remains directly importable only for standard-library internals and
the direct-libuv extension contract below.

Lua's `require`, for its part, finds a generated logical loader through
`package.path`; that loader finds its physical provider through
`package.cpath`, loads it globally, and invokes the module's exact
`luaopen_*` entry (see [Requiring a Titan
module](lua-interop.md#requiring-a-titan-module)). Titan's installed Lua
default includes `<root>/lib/titan/0.6/?.so` and the standard loader root.
A qualified standard name such as `titan.os` therefore runs
`<root>/share/lua/5.5/titan/os.lua`, which opens the canonical DSO
`<root>/lib/titan/0.6/titan.so`. Default Titan imports select that same
physical file by validating the `titan.os` callable metadata; `--static`
prefers the paired self-describing `titan.a`. Installation creates no child
DSOs, parent-level or `lib/lua` copies, symbolic links, or hard links. The
installer does not provide cross-version migration or cleanup.

## Static and dynamic linking

Module dependencies are resolved *compiled first*:

* If an imported module is found in a shared provider, the compiler recovers
  its callable type metadata and generated code **dlopens** that selected
  provider at run time.
* If it is found in a self-describing static provider, the compiler recovers
  the equivalent metadata from the archive and links that archive into the
  result; cross-module calls are direct C calls. The default prefers the DSO
  pass, while `--static` prefers the archive pass.
* If there is no binary, but a flat or folder source representation is found,
  it is compiled and **statically linked** into the artifact being built.
  Cross-module calls are then direct C calls.
* An import spelling ending in `.titan` is the explicit exception: it removes
  the marker from the logical name and performs source lookup without probing or
  falling back to a compiled provider. It also grants local visibility only to
  that written alias. An ordinary import that eventually resolves to source
  remains public-only.
* A module named explicitly on the `titanc` command line is a build root, so
  its source is selected before any same-named binary. This is why
  `titanc titan.uv` rebuilds the `titan/uv/uv.titan` folder module while that
  module's own imports
  still resolve through the selected compiled-format order first.

`--static` is a preference rather than a static-only mode: a missing archive
can fall back to a DSO and then source, and the system linker is not passed
`-static`. See [Static compiled modules](static-compiled-modules.md) for the
full composition and transitive-owner rules.

This ordinary ordering is enough to keep the installed standard-library
provider from being displaced accidentally by source files in `./titan`.
Changing `TITAN_PATH` so the installed provider is hidden deliberately selects
a different module graph.

A binary extension DSO may use that ordering to call bundled libuv directly.
Its source must both `import "uv"` and `foreign import "uv.h"`, and its link
must leave `uv_*` unresolved rather than adding `-luv` or a static archive.
Titan maps every compiled runtime dependency with
`RTLD_LAZY | RTLD_GLOBAL`. Lazy binding lets the extension's ordinary
unresolved libuv calls remain unbound until its generated initializer loads the
explicit `uv` import globally. `RTLD_NOW` would fail before that initializer
could run, while a provider loaded `RTLD_LOCAL` later would not satisfy the
extension's lazy bindings. There is no libuv-specific dependency
classification or loader path; the compiler's distinct interface-inspection
loader remains `RTLD_LAZY | RTLD_LOCAL`. This Titan-side contract does not
cover native constructors, imported data, or taken function addresses whose
relocations must resolve while the extension is being mapped. A Lua caller
loading the extension directly must first run `require "titan.uv"`. Like every
generated logical loader, `titan/uv.lua` finds the physical `titan` provider
through `package.cpath`, obtains the native support table with
`require "titan"`, promotes the canonical `titan.so` through its lazy/global
loader, and invokes the exact `luaopen_titan_uv` entry. The promotion is needed
because Lua's ordinary C searcher initially maps the same image eager/local for
the bare support load.

System-mode extensions may instead link the same shared libuv selected by
pkg-config.

Because this explicit Lua preload establishes the provider before the
extension is mapped, the Lua route also supports eager relocations and native
constructors. It can resolve native symbols for a Lua-only extension without a
Titan `uv` import; the import is nevertheless required for the same module to
work through Titan's runtime loader. See
[Direct libuv extensions](ffi.md#direct-libuv-extensions) for the build
contract.

A statically linked dependency is still a module of its own from Lua's point
of view. Its generated logical loader points at the enclosing provider, so if
`main.so` embeds `geom.point` and a Lua script also `require`s `geom.point`,
both refer to the same module instance in that Lua state, with the same
record/union/Interface identities and the same module variables.

## Standalone executables

If exactly one of the modules given to `titanc` defines a function with
the exact signature

```lua
-- Titan
function main(args: {string}): integer
```

the output is a standalone executable instead of a library provider. A flat
module `foo.bar` produces `foo/bar`; a folder module produces the collision-free
`foo/bar__main` beside the unchanged `foo/bar__entrypoint.c`. The
signature is exact: neither an input-variadic parameter nor a flexible result
tail is allowed (the fixed parameter and return types may be spelled through
transparent aliases). All
requested modules and dependencies selected from source or static providers
are linked directly into the binary. Dependencies selected from DSOs remain
dynamic. Qualified standard-library dependencies therefore use the installed
`titan.so` by default, while `--static` prefers `titan.a`.
After `luaL_openlibs`, the executable parses the
inherited `package.cpath` for its `/lib/lua/5.5/?.so` entry, adds
`<root>/lib/titan/0.6/?.so` if it is absent, and initializes the Titan module
path from that same root. Deploy the standard provider and loaders as described
under [where modules are found](#where-modules-are-found). `args[1]` onward
contain only the user-supplied arguments; index 0 is absent and the executable
name is not stored. Therefore `#args` is the argument count. The integer returned by
`main` becomes the process exit status; an uncaught run-time error
prints `<program name>: <error message>`, `stack traceback:`, and
tab-indented unified traceback frames through the Titan `main` frame to
standard error, then exits with a failure status. The synthetic Lua
bootstrap is not shown (see [Error handling](error-handling.md)).

Before it loads the main module, the generated entrypoint publishes the
process's original `argc` and `argv`. If a transitive import initializes
`titan.uv`, that canonical provider calls libuv's required `uv_setup_args`
once and returns its possibly replaced argument vector to the entrypoint before
the `args` table is built. This startup contract is also why
[`os.exepath`](standard-library-os.md#directories-and-host-identity) is
available in compiled Titan programs but not when the standard module is
loaded by a Lua or other embedding host.

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

Compiled Titan modules and executables run against an unmodified Lua loader —
no `loadlib.c` patch and no custom build flags beyond compiling the Lua
sources with `-fPIC`. Each DSO and executable links the matched `liblua.a`;
a produced static provider deliberately omits that common final input, so its
consumer supplies the matching Lua archive once. Several logical modules in
one final native image share that Lua instance.
This is why the compiler needs a built Lua source tree and not just an
installed interpreter. This was a deliberate packaging decision (pull request
#231), together with the removal of semantic
global C state from generated modules (#233/#235): a Titan module keeps its
state in registry/GC-owned objects per Lua state. Per-image C statics may hold
only nonsemantic native wiring or caches, so the same module can be loaded into
several Lua states in one process, each with its own copies of the
module variables — see
[Multiple Lua states](lua-interop.md#multiple-lua-states). Each
compiler release does target one specific Lua version (currently
Lua 5.5), because the generated code works against that version's
internals.

The bundled direct-libuv extension contract also works with stock Lua 5.5. The
installed `$ROCKS_TREE/share/lua/5.5/titan/uv.lua` module uses the native
support table's lazy/global loader to promote the shared `titan.so` provider
before it invokes the exact native entry. A stock interpreter can reproduce
Titan's configured search paths with:

```sh
export LUA_PATH_5_5="$ROCKS_TREE/share/lua/5.5/?.lua;$ROCKS_TREE/share/lua/5.5/?/init.lua;;"
export LUA_CPATH_5_5="$ROCKS_TREE/lib/titan/0.6/?.so;$ROCKS_TREE/lib/lua/5.5/?.so;;"
```

The ordinary `/lib/lua/5.5/?.so` template is Titan's root-discovery anchor. If
it is omitted, also set
`TITAN_PATH_0_6="$ROCKS_TREE/lib/titan/0.6"`. Titan still targets the exact
Lua 5.5 runtime ABI and internals; using the stock loader does not make a module
compatible with another Lua version or configuration.
