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
* a **type alias** declaration: `[local] type Name = type` (see
  [Type aliases](type-aliases.md));
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
function may not share a name with a module variable or an import. Type aliases
use a separate type-only namespace: they may share a spelling with those value
declarations, but not with another alias or a record.

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

* **Top-level declarations themselves are checked in source order, except for
  type aliases.** A module-variable declaration can only use ordinary imports
  and record value namespaces that appear *above* it in the file; referring to
  one declared below is a compile-time error (`module '...' referenced by type
  not found`, or `record type '...' in context of record constructor does not
  exist`). Alias names, however, are predeclared module-wide and may be used in
  earlier signatures, annotations, and record fields. Alias chains may point
  forward to other aliases or records. Imports remain source ordered, so an
  import used by a qualified alias target must already have been declared when
  that target is first resolved. In practice: put imports first, then records
  and variables.

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
* calls to an imported C type's `.new()` or `.new_array(count)` pseudo-
  constructor, with a constant `count`;
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
work as module-variable declarations. Owned C constructors work as well, for
example `local state = c.State.new()` or
`local slots = c.Slot.new_array(4)`. The constructors run once when that module
instance initializes; the resulting objects are rooted in its GC-traced state.
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
check. Exported record declarations serve two roles: their types are referenced
as `alias.Name` in annotations, and their run-time record functions as
`alias.Name.new(...)` or `alias.Name.make(...)`. An exported type alias is only
the first of these: `alias.Name` is valid as a type but creates no run-time
record-function namespace. Construct a re-exported record through the module
that owns its record declaration.

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
the dependency is selected from source or from a compiled module at compile
time. In the words of the same
discussion: "`require` is our analogue to `dlopen`, while the static
import is more like `#include`/`-l`. ... Let's just call it `import`,
make it an evident keyword, and make a clear distinction between the
static `import` and the dynamic `require`."

There is consequently no way to `require` a Lua module from Titan code
today: `import` loads Titan modules and `foreign import` loads C
headers (see [the C FFI](ffi.md)). Lua callables can still enter Titan
as function-typed values — for example, as an argument from Lua — and
Titan can call them normally (see
[Lua interoperability](lua-interop.md#calling-lua-from-titan)).

## Compiling modules: `titanc`

The compiler driver is invoked with dot-separated *module names*, not
file paths:

```sh
titanc [--print-ast] [-v] [--lua <luasrc>] [--tree <srcroot>] [-l lib1,lib2] <module>...
```

* `--tree <srcroot>` sets the source tree root (default `.`); module
  `foo.bar` is looked up at `<srcroot>/foo/bar.titan`.
* `--lua <luasrc>` points a source-checkout compiler at a complete Lua
  source/build tree. Checkout developer mode otherwise uses
  `lua-5.5.0/src`. An installed compiler rejects this override and always
  uses its matched `<root>/src/lua-5.5.0` headers, `liblua.a`, and
  `libtitan.a`.
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

An installed compiler links `<root>/lib/libtitan.a`; compiler development
directly from the repository lazily rebuilds and links
`titan-runtime/libtitan.a`. Both archives contain exactly `titan.o`,
`titan_coro.o`, and `titan_uv.o`; neither driver mode links `titan.o`
directly. Vendored `libbacktrace.a` and the matching `liblua.a` remain separate
link inputs, and the `titan.so` Lua support module is built separately from
`titanlib.c`.

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
  semicolon-separated list of plain directories taken from
  `TITAN_PATH_0_12`, or `TITAN_PATH` if that is unset. Otherwise the default
  is `.;<root>/lib/titan/0.12`. An installed `titanc` recovers `<root>` from
  the first literal `package.cpath` entry ending in
  `/lib/lua/5.5/?.so`. The same path is used at run time by compiled modules
  that load dependencies dynamically; a `;;` in the run-time environment
  override inserts the default path.

Here `<root>` is the Titan SDK/rocks-tree root. `PREFIX` owns Lua and LuaRocks,
while `ROCKS_TREE` owns the Titan SDK and standard modules. The supported
developer installation currently makes those paths equal, which is why the
driver can discover the Titan root from Lua's `package.cpath`; the names do not
have inherently identical ownership.

The standard-library names `coroutine`, `uv`, `async`, `timer`, `fs`, `net`,
and `os` are parser sugar for the qualified module names `titan.coroutine`,
`titan.uv`, `titan.async`, `titan.timer`, `titan.fs`, `titan.net`, and
`titan.os`. The qualified names then
follow the ordinary module lookup rules. Thus `local os = import "os"` means
Titan's `titan.os` module without colliding with Lua's own `os` library, which
is not importable as a Titan module.

Application scheduling uses `import "async"` (or Lua's
`require "titan.async"`). `titan.uv` is the private Runtime/libuv provider and
remains directly importable only for standard-library plumbing and the
direct-libuv extension contract below.

Lua's `require`, for its part, finds the `.so` through Lua's ordinary
`package.cpath` — a compiled Titan module is a regular Lua C module
(see [Requiring a Titan module](lua-interop.md#requiring-a-titan-module)).
Titan's installed Lua default puts `<root>/lib/titan/0.12/?.so` before the
ordinary `lib/lua` templates, and each standalone program ensures that same
entry is present. A qualified standard name such as `titan.os`
therefore resolves the single canonical file
`<root>/lib/titan/0.12/titan/os.so`. Titan imports resolve that same file by its
qualified name. Installation creates no parent-level or `lib/lua` copy and
requires no symbolic- or hard-link alias.

## Static and dynamic linking

Module dependencies are resolved *binary first*:

* If an imported module's compiled `.so` is found on the binary path, the
  compiler recovers the module's
  interface from type information embedded in the library, and the
  generated code **dlopens** the dependency at run time, finding it on
  the binary search path. The binary wins even when source with the same module
  name is visible under `--tree`.
* If there is no binary, but the imported module's `.titan` source is found, it
  is compiled and **statically linked** into the artifact being built.
  Cross-module calls are then direct C calls.
* A module named explicitly on the `titanc` command line is a build root, so
  its source is selected before any same-named binary. This is why
  `titanc titan.uv` rebuilds `titan/uv.titan` while that module's own imports
  still resolve binary first.

This ordinary ordering is enough to keep the installed standard-library
binaries from being displaced accidentally by source files in `./titan`.
Changing `TITAN_PATH` so the installed binary is hidden deliberately selects a
different module graph.

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
loading the extension directly must first run `require "titan.uv"`. The
installed `titan/uv.lua` loader finds the canonical
DSO through `package.cpath`, maps it with `package.loadlib(path, "*")`, and
then invokes the exact `luaopen_titan_uv` entry. Every other Lua C module keeps
stock Lua's local-loading behavior. The provider does not reopen itself.
System-mode extensions may instead link the same shared libuv selected by
pkg-config.
Because this explicit Lua preload establishes the provider before the
extension is mapped, the Lua route also supports eager relocations and native
constructors. It can resolve native symbols for a Lua-only extension without a
Titan `uv` import; the import is nevertheless required for the same module to
work through Titan's runtime loader. See
[Direct libuv extensions](ffi.md#direct-libuv-extensions) for the build
contract.

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
parameter and return types may be spelled through transparent aliases). All
requested modules and dependencies selected from source are statically bundled
into the binary.
Qualified standard-library dependencies are normally found as installed
binaries first and therefore remain dynamic, just like other binary modules.
After `luaL_openlibs`, the executable parses the
inherited `package.cpath` for its `/lib/lua/5.5/?.so` entry, adds
`<root>/lib/titan/0.12/?.so` if it is absent, and initializes the Titan module
path from that same root. Deploy those standard DSOs as described under
[where modules are found](#where-modules-are-found). `args` is
Lua-style: `args[0]` is the program name and `args[1]` onward are the
arguments, so `#args` is the argument count. The integer returned by
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
sources with `-fPIC`. Each compiled module statically embeds the parts
of the Lua core it uses (the build links `liblua.a` into every `.so`
and executable), which is why the compiler needs a built Lua source
tree and not just an installed interpreter. This was a deliberate
packaging decision (pull request #231), together with the removal of semantic
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
installed `$ROCKS_TREE/share/lua/5.5/titan/uv.lua` module performs the global
provider load through Lua's public `package.loadlib` API before it invokes the
native entry. A stock interpreter can reproduce Titan's configured search
paths with:

```sh
export LUA_PATH_5_5="$ROCKS_TREE/share/lua/5.5/?.lua;$ROCKS_TREE/share/lua/5.5/?/init.lua;;"
export LUA_CPATH_5_5="$ROCKS_TREE/lib/titan/0.12/?.so;$ROCKS_TREE/lib/lua/5.5/?.so;;"
```

The ordinary `/lib/lua/5.5/?.so` template is Titan's root-discovery anchor. If
it is omitted, also set
`TITAN_PATH_0_12="$ROCKS_TREE/lib/titan/0.12"`. Titan still targets the exact
Lua 5.5 runtime ABI and internals; removing the loader patch does not make a
module compatible with another Lua version or configuration.
