# Modules

A *Titan module* is the unit of compilation, namespacing, and distribution.
Its source may be one flat `.titan` file or a canonical main plus immediate
`.titan` contributors in a [folder module](folder-modules.md). Both forms
compile as one logical module. In library mode, one or more related logical
modules are linked into a physical provider (a DSO/archive pair on Linux and
macOS, a DLL on Windows); Lua programs use `require`, through Titan's package
searcher, and other Titan modules use
`import` without exposing that physical grouping. A module that defines a
[`main` function](functions.md) becomes a standalone executable instead. This
chapter describes what goes inside a logical module, how modules reference
each other, and what the compiler produces. See
[Multi-module libraries](multi-module-libraries.md) for the provider and
lookup rules.

The native output, archive, and static Lua examples in this chapter describe
Linux and macOS. See [Experimental Windows compilation](#experimental-windows-compilation)
for the Windows provider and runtime requirements.

## What a module is made of

The top level of a module is a sequence of *declarations*, optionally followed
by one root `do ... end` [module initialization block](#module-initialization-block).
A declaration is one of:

* an **import**: `local m = import "modname"`;
* a **foreign import** directive: `foreign import "header.h"` (see
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

```titan
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
declarations first, then contributors in numeric-byte order of their logical
filenames, then the main initializer
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

* **A module-variable declaration sees only earlier ordinary Titan imports and
  module variables.** Ordinary import aliases are available regardless of
  placement to other declarations. At each module-variable declaration, its
  type annotation and initializer see only those aliases and module variables
  that occur earlier in the logical order. The builtin `ffi` namespace already
  contains the complete ordered module C environment, including declarations
  and macros from foreign directives written later. They still see every record, union,
  Interface, type alias, ordinary function, method, nominal function, and
  synthesized constructor, wherever those declarations occur. This visibility
  does not make every visible declaration legal in an initializer: the separate
  [initialization-dependency rule](#initializer-dependencies) still applies.

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
computed initialization that depends on the module's own variables or
callables:

```titan
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
appear only in the selected main source; the compiler places it after every
contributor declaration. It may call contributor-local functions because all
files share one module scope. Ordinary nested `do` statements remain legal in
every source file.

The block is also the sole assignment region for an initializer-less const
module variable owned by this logical module. Permission follows this root
function frame through nested blocks, but does not flow into a function or
lambda called or created from it. An explicit source import does not grant an
importer's initializer authority over the producer's const slots.

## Builtin names and keyword-named members

`ffi` is a readonly builtin namespace binding. A declaration may shadow it;
assignment cannot replace the builtin itself. In ordinary function and method
bodies and the module initializer, `L` is the current Lua-state pointer and `M`
identifies the current module. `M.member` selects an owner declaration even if a
local shadows its name, and can select local module members. Body-local type
annotations may use `M.Type` to select an owner type despite a local or generic
shadow with that spelling. The explicit
`M as foreign *Udata` cast exposes the module's native address at the trusted
FFI boundary. The cast needs the `Udata` declaration: add
`foreign import "titan/ffi.h"` to the module that writes it.

Top-level declarations and member selectors admit keyword spellings where the
grammar uses `AnyName`. Local bindings and parameters still require `Name`.
Use `M.end`, for example, to select a module member named `end`. The primitive
Titan type words `boolean`, `integer`, `float`, `string`, and `value` are not
lexer-reserved words. Full productions are in [the grammar](grammar.md).

## Module variables

A module-variable declaration has the form

```text
-- Titan
[local] [const] <name> [: <type>] [= <expression>]
```

A declaration needs a type annotation, an initializer, or both; a bare name is
not a module declaration. Module names have no `?` inference suffix; use an
explicit optional type such as `state: State?`. With an initializer and no annotation, the type is
inferred. A mutable or const variable may omit its initializer only when its
explicit type admits nil, and then starts as nil/NULL. With an annotation, the usual
[assignment adjustments](types.md#relations-and-boundaries-no-subtyping)
apply, so `pi: float = 3` declares a float-typed variable holding `3.0`.

An initialized const module variable is never assignable. An initializer-less
const slot can be assigned only while code
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

### Initializer dependencies

A mutable or const module-variable initializer runs when the module is loaded,
not at compile time. It may use:

* literals and Array, Map, record, or union construction;
* foreign constants, variables, fields, indices, and function calls;
* visible imported-module members, including variables, functions, constructors,
  and methods; and
* ordinary operators, casts, type tests, indexing, and calls composed from those
  expressions.

Every expression evaluated by the initializer must obey the same rule,
including call arguments, surplus arguments that are evaluated and discarded,
container keys and values, and method receivers. Imported modules are fully
initialized first, and cyclic imports are forbidden. An import must still be
visible at the declaration; this rule does not change the earlier-import
frontier or explicit-source-import visibility.

```titan
local string = import "string"
foreign import "limits.h"
foreign import "stdlib.h"

const maximum: integer = ffi.LLONG_MAX as integer
local magnitude: integer = ffi.abs(-7)
local banner = string.rep("=", 3)
```

An initializer cannot evaluate a reference to the current module's own
variables, functions, or methods, even if the declaration is earlier, const,
or reached through a type alias. This prevents a call from reading
partially initialized module state. The compiler-generated record `new` and
union-variant constructors are exceptions: their arguments are checked, and
their bodies only allocate and fill the nominal value. An own-module custom
`new` or other user-written nominal function is not an exception, and neither
is an own function or constructor used as a value.

```text
x = 10
y = x + 1                   -- rejected: reads an own-module variable
z = compute()               -- rejected: calls an own-module function
f = compute                 -- rejected: an own function value
```

Creating a callable does not run it. An initializer may therefore store an
anonymous function, an own method bound to a receiver that obeys this rule
(such as `Counter(0):current`), or an Interface value converted from an own
record or union. It may store them directly or inside Arrays, Maps, record or
union construction, operators, and written casts. A lambda's body may use the
module's own declarations under the ordinary visibility rules, because it runs
only when called. A value of an own record or union type that has methods
counts as an own callable too: once the module converts that type to an
Interface anywhere, other code can reach those methods through a
[compiler-witnessed conversion](interfaces.md#coercion-is-not-consistency-or-subtyping)
from `value`.

Binding `Counter(0):current` evaluates only its receiver, so it is accepted. A
named own function such as `compute` is an own-module declaration and is
rejected even when the initializer only stores it.

```titan
local seed: integer?

record Counter
    start: integer
end

function Counter:current(): integer
    return self.start + seed
end

local callbacks = {function(): integer return seed end}
local current = Counter(1):current

do
    seed = 41
end
```

A call that the initializer evaluates must not receive or invoke such a value,
because the callee could run the module's own code before the module's
variables are initialized. An own callable is rejected as an argument of an
evaluated call, including one nested inside that argument's containers,
constructors, operators, or casts, and as the called expression or the
receiver of an Interface method call. This applies even to a lambda that
captures nothing. Generated constructors only store their arguments, so they
create no such exposure, but they do not hide an own callable from an
enclosing call. The diagnostic for an anonymous function differs from the one
for other own callables.

```text
a = Counter(1):current()                  -- rejected: invokes an own method
b = sorter.sort({3, 1}, function(x: integer, y: integer): boolean
        return x < y end)                 -- rejected: passes a lambda to a call
c = registry.add({Counter(1):current})   -- rejected: nested in a call argument
```

Only own implementations count. An Interface declared by this module may
dispatch to a method implemented by an imported record or union, and imported
bound methods may be passed to calls.

An imported generated record constructor stores its arguments without calling
them only while its provider keeps the generated `new`. When an initializer
stores an own callable through one, directly or nested in another stored
argument, the compiled consumer therefore also requires the generated default
constructor. A replacement provider that overrides `new` is rejected as
incompatible when the consumer loads, before any of its initializers run; see
[Replacing shared-library dependencies](binary-compatibility.md#private-record-fields-and-construction).
Imported construction with callback-free arguments depends only on `new`'s
signature, so such a consumer observes a compatible custom `new`.

Initializers execute once per module instance, in declaration order. The
checker does not evaluate calls at compile time; their observable effects and
failures occur during module loading. Allocated results are rooted in the
module's GC-traced state. Use the final [module initialization block](#module-initialization-block)
when initialization must read the module's own state or call its own
callables.

## Importing other modules

An `import` declaration makes another Titan module's exported members
available under a local alias:

```text
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

```titan
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

```titan
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
Separate shared-library consumers resolve the provider's current slots when
loading, so compatible declaration reordering preserves these references and
their canonical identity. Direct `geom.norm(p)` calls use the native function
entry independently of the first-class closure.

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
titanc [--print-ast] [--pretty-print] [-q|-v] [-j jobs] [--c-parts n] [--static] \
  [--source-first] [--incremental] [-c|--compile-only] \
  [--test [--test-dir dir]... [--test-exclude module]...] [--exe path] \
  [--no-uv-bootstrap] [--no-line-directives] [--lua <luasrc>] \
  [--tree <srcroot>] [-T|--target <label>] [-o|--output <directory>] \
  [-I dir]... [-D name[=value]]... [--cflag arg]... \
  [-L dir]... [-l lib1,lib2]... [--ldflag arg]... \
  [--c-source file]... [--print-c-objects] [-X object...] <module>...
```

`titanc --print-root` is a separate query: it prints the selected installation
root followed by a newline and exits without compiling, probing C tools, or
creating a probe cache. Do not pass module names with the query. The root is
`TITAN_ROOT` when that is set and non-empty, otherwise the parent of the
directory that contains the Lua interpreter running `titanc` (symlinks
resolved), so an installation at `<root>/bin/lua` reports `<root>`, including
on Windows and after the tree is moved. `TITAN_PREFIX` only selects the
C-probe cache and does not affect this query. The query ignores `-T`/`--target`
and `TITAN_TARGET`, whatever their values. An undiscoverable installation
reports an error and exits with status 1. Build tools can use this query to
find the matching SDK rather than infer the installation layout from the
compiler launcher filename, and compiled programs use it as their [SDK
fallback](#the-titan-path).

* `--tree <srcroot>` sets the source tree root (default `.`); module
  `foo.bar` is looked up first at the folder main
  `<srcroot>/foo/bar/bar.titan`, then at flat source
  `<srcroot>/foo/bar.titan`. The value may be an ordered, semicolon-separated
  list of roots (quote it in the shell, as in `--tree 'src;tests'`); each
  module is looked up in the roots in order, and the first root that has it
  wins.
* `-T/--target <label>` selects the compilation target for [target source
  selection](target-source-selection.md), as a separate argument or as
  `--target=<label>` (`-t` stays `--tree`). Without it, `titanc` reads
  `TITAN_TARGET`; absent or empty selects the host. The host's own OS label
  (`linux`, `darwin`, or `windows`) and, on Linux and macOS hosts, `browser`
  are accepted; `native`, other OS labels, and unknown values are errors.
  `browser` compiles objects, library archives, and `.mjs`/`.wasm` programs
  and tests with Emscripten and requires `--output` ([Compiling for the
  browser target](browser-target.md)).
  Each module source file `name.titan` may have variants
  `name.<label>.titan`, and the target selects one file per logical filename.
* `-o/--output <directory>` creates the destination and missing parents, then
  writes generated files beneath it. Generated C, objects, and headers recreate
  the selected source root's hierarchy there; final providers,
  executables, and coverage files also use that tree. Prefer this option to
  keep generated files together. See [Output directories](output-directory.md).
* `--lua <luasrc>` points a source-checkout compiler at a complete Lua
  source/build tree. Checkout developer mode otherwise uses
  `lua-5.5.1/src`. For a stock Lua tree, see
  [A stock Lua tree](installation.md#a-stock-lua-tree). An installed compiler
  rejects this override and always uses its matched `<root>/src/lua-5.5.1`
  headers, `<root>/lib/liblua.a`, and `<root>/lib/titan/0.6/libtitan.a`.
* `-l/--link`, `-L/--library-dir`, and `--ldflag` add native libraries,
  library directories, and single link arguments to final links, in
  command-line order. `-I/--include-dir`, `-D/--define`, and `--cflag` add
  include directories, macro definitions, and single compile arguments to C
  header checking, probes, and generated C. See
  [native compiler and linker switches](output-directory.md#native-compiler-and-linker-switches).
* `--c-source <file>` compiles and certifies an authored or generated C file
  with the same native flags and links its object before `-X` payloads. On
  Windows it omits Titan's Lua DLL import definitions; see [the Lua DLL and C
  helpers](windows-build.md#the-lua-dll-and-c-helpers). With
  `-c`, `--print-c-objects` prints each certified object's absolute path.
* `--exe <path>` selects the exact standalone or test executable path,
  relative to the working directory.
* `-j/--jobs <jobs>` caps the module-frontend worker processes and native
  compiler processes (generated-C translation units and batches of C
  validation probes) that one `titanc` run keeps active at once. It defaults
  to the positive integer in `TITAN_JOBS`, or to four when that variable is
  unset. On Linux and macOS, values above one require the standard POSIX
  `mkfifo` utility. Inside a parent GNU Make the run also shares Make's job
  slots when the jobserver allows it; see
  [Compiler jobs and GNU Make](build-profiles.md#compiler-jobs-and-gnu-make).
  Diagnostics and generated files do not depend on the job count. With
  `--jobs 1` (or, on Linux and macOS, under `make -j1`) every C probe runs
  when reached.
* `--c-parts <n>` sets the maximum number of C translation units into which a
  module with at least 2 MiB of generated C definitions is split, so its parts
  can compile in parallel. It defaults to the positive integer in
  `TITAN_C_PARTS`, or to 4 on Linux and 1 elsewhere; `1` disables splitting.
  It is independent of `--jobs`. See [Native build
  profiles](build-profiles.md#split-modules).
* `--static` prefers self-describing Titan `.a` providers over `.so`
  providers for ordinary dependencies. It still permits DSO/source fallback
  and does not request a fully static system executable. Windows rejects this
  option and selected Titan archive providers.
* `--source-first` prefers available source dependencies to compiled providers,
  with compiled fallback for ordinary source misses. It does not grant private
  visibility to ordinary imports.
* `--incremental` reuses each source module object, `--c-source` object, and
  final link whose certificate still matches its sources, compiler, native
  configuration, C headers, dependency interfaces, and bindings; `-v` explains
  every miss. `-c/--compile-only` emits objects and headers without linking;
  without `--incremental` it rebuilds every module in the requested closure,
  while `-c --incremental` certifies explicit roots like any dependency. See
  [Incremental and separate compilation](incremental-compilation.md) for the
  certificate contents, Make patterns, and incompatible options.
* `--test` source-prefers the requested roots' complete dependency graph,
  discovers public `test_*` functions, and links a standalone native test
  executable even without an application `main`. `--test-dir <dir>` adds every
  conventionally named test module below a directory as a root, and
  `--test-exclude <module>` removes one discovered root. See
  [Testing Titan code](standard-library-test.md).
* `--no-uv-bootstrap` is valid only when the result is a normal standalone
  executable or a `--test` executable. The generated entrypoint still
  initializes every imported module and preserves the installed bootstrap
  registry value, but calls `main(args)` directly instead of invoking that
  value. This is an explicit lifecycle-ownership option, not a way to disable
  `titan.async` initialization or its process-startup policy.
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
* `-q/--quiet` turns off progress reporting. Standard error then carries only
  diagnostics and native tool output, as titanc printed before progress
  reporting existed. See [Build output](#build-output).
* `-v/--verbose` writes every C tool command line and incremental hit and miss
  decision to standard error, where compiler output also goes, plus the
  formatter command line with `--pretty-print`. Progress lines are added in
  their plain one-line form. `-q` and `-v` together are a usage error.
  `--print-ast` dumps the parsed AST.

`titanc` checks and compiles each module of the requested closure after its
dependencies, running independent modules in parallel. It reports *all*
errors in dependency order and exits with status 1 without linking if any
module failed; a module that depends on a failed one is skipped, while
independent modules may already have published their objects. With
`--incremental`, unchanged modules supply their declarations from certified
objects without being parsed or checked again.

`clang-format` is needed only for `--pretty-print`; `CLANG_FORMAT` selects a
different compatible command. In that mode Titan formats every generated `.c`
in place before invoking the C compiler and every generated `.titan.h` before a
compiler check consumes or publishes it. A formatter failure aborts native
compilation and provider publication. Default builds do not discover or invoke
a formatter.

Compilation goes through C: each logical module becomes one C translation
unit, written under the selected output directory (beside its canonical source
when `--output` is omitted), and the system C compiler (`cc`,
with `--std=c99 -O3 -Wall -fPIC`) does the rest. Linux also enables
`-flto=auto -ffat-lto-objects` so final links can optimize across object boundaries
while objects retain native metadata sections. macOS uses ordinary native
objects without default LTO. See [Optimization and toolchain settings](incremental-compilation.md#optimization-and-toolchain-settings).
On Linux and macOS, a single-root library build uses that root as its physical
provider and produces these paths:

| Source form for `foo.bar` | Generated C/object | Provider pair | Entrypoint | Executable |
| --- | --- | --- | --- | --- |
| flat `foo/bar.titan` | `foo/bar.c`, `foo/bar.o` | `foo/bar.so`, `foo/bar.a` | `foo/bar__entrypoint.c` | `foo/bar` |
| folder `foo/bar/bar.titan` | `foo/bar/bar.c`, `foo/bar/bar.o` | `foo/bar.so`, `foo/bar.a` | `foo/bar__entrypoint.c` | `foo/bar__main` |

The provider column applies in library mode; the entrypoint and executable
columns apply in `main` program mode. Library mode writes no Lua files: Lua
code loads the provider through [Titan's package
searcher](lua-interop.md#requiring-a-titan-module).

In `--test` mode the first requested root's executable column applies even when
no root declares `main`; the generated runner is the sole main. Its runner and
entrypoint C/object files use `__test_runner` and `__test_entrypoint` suffixes
beside that executable stem. The runner ordinarily imports `titan.test` and
calls its public `run` function; the standard module is not rebuilt specially
for tests. See the
[test chapter](standard-library-test.md#discovery-and-compilation).

With several no-`main` roots, Titan publishes one paired provider at their longest common
dotted-component prefix. For example, `titanc foo.left foo.right` produces
`foo.so` and `foo.a`; it does not produce child providers. Roots without a
common component are rejected. The complete
grouping, lookup, ownership, and reserved-name rules are in
[Multi-module libraries](multi-module-libraries.md); archive precedence,
metadata, linking, and `--static` are in [Static compiled
modules](static-compiled-modules.md).

With `--output`, all paths in the table are below that output directory, and
generated C and objects are relative to the selected source root. Without the
option, the provider pair, executable, and entrypoint paths are
relative to the directory `titanc` runs in. Generated C and objects are beside
the canonical flat source or folder main path, even when `--tree` points
elsewhere or a [target variant](target-source-selection.md#generated-files-keep-logical-names)
of it is selected. A folder
contributor never produces a separate C file, object, DSO, archive, or
executable. The folder program's `__main` suffix avoids colliding with its
source directory; the logical module name and entrypoint path remain
unchanged.

Use separate output directories to keep configurations with different
compiler modes or flags side by side. Sharing one output directory is also
correct: certification rebuilds whatever a configuration change affects, and
`.titan-build.lock` serializes concurrent invocations, but alternating between
configurations then rebuilds on every switch. An application build and a
`--test` build can share one output directory and reuse unchanged production
objects. Without `--output`, generated C and objects stay beside the sources,
so different working directories do not isolate them; stage a separate source
tree for each configuration and point `--tree` at that copy.

An installed compiler links `<root>/lib/titan/0.6/libtitan.a`; compiler development
directly from the repository lazily rebuilds and links
`titan-runtime/libtitan.a`. Both archives contain `titan.o`, `minicoro.o`,
`titan_path.o` (module location), and `ltitanlib.o` (the Lua support module);
a link pulls in only the members it references. Source-defined
foreign callbacks live in their generated module objects, and neither driver
mode links `titan.o` directly. Vendored `libbacktrace.a` and the matching `liblua.a` remain separate
link inputs. The Lua support module is also installed on its own as the
ordinary Lua C module `<root>/lib/lua/5.5/titan.so` (`titan.dll` on Windows);
the standard-library provider pair does not contain it.

*Implementation note:* the driver and the exact compiler invocations
are described in [the driver documentation](../implementation/driver.md);
the structure of the generated C is in
[the code generator overview](../implementation/codegen-overview.md).

### Build output

`titanc` reports build progress on standard error. Standard output is reserved
for requested results such as `--print-root`, `--print-ast`, and
`--print-c-objects`, so those stay machine-readable. Three modes select what
standard error carries:

| Mode | Selected by | Standard error |
| --- | --- | --- |
| quiet | `-q`/`--quiet` | Diagnostics and native compiler and linker output only, as before progress reporting existed. |
| progress | default | The quiet output plus progress: which Titan module is being compiled and in which phase. It never shows command lines. |
| verbose | `-v`/`--verbose` | The verbose command and hit/miss lines plus progress, always in the plain form. |

Progress names these events:

- **Each module that is compiled:** `parsing`, `checking`, `generating C`, and
  `compiling C` (with the part count when a [split module](build-profiles.md#split-modules)
  has more than one part), then `done` with the elapsed time, or `failed`.
- **Modules restored by `--incremental`:** no line each, but one summary,
  `N modules up to date`.
- **Each `--c-source` file that is compiled:** a `compiling C source` step.
  A certified hit is only counted in the final summary.
- **Each final link:** a `linking` step named by the output's file name. A
  final-link certificate hit is reported as `<output> up to date`.
- **The end of the build:** `Finished in <time>` with the counts of compiled
  and up-to-date modules, the outputs it linked, and `<output> up to date` for
  a final-link certificate hit. On failure, it prints
  `Failed after <time>` instead, followed by the diagnostics, unchanged. An
  invocation that fails before any build work, such as a usage error, prints
  only its error.

The **plain** form prints one self-contained line per event, so it reads well in
logs and stays readable when parallel builds interleave their output:

```text
app.one .................. parsing
app.one .................. checking
app.one .................. generating C
app.one .................. compiling C
app.one .................. done 0.3s
1 module up to date
app.so ................... linking
app.so ................... done 0.1s
Finished in 0.5s: 1 compiled, 1 up to date, linked app.so
```

The **live** form is for a terminal. Each finished module or link leaves one
persistent line, and a region below it redraws in place: one row for each
module or step in progress, with a spinner, its phase and its elapsed time,
and a footer with the number of modules done (including those up to date) out
of the total, the number running, the number up to date, and the elapsed time.
Output from the compiler and linker is printed above the region, so it is never
overwritten. The region is erased when the build finishes or fails. The cursor
is never hidden.

`titanc` picks the live form only when all of these hold. Otherwise it uses
the plain form:

- standard error is a terminal;
- `TERM` is not `dumb`;
- `-v` is absent;
- `MAKEFLAGS` advertises no jobserver (`--jobserver-auth` or `--jobserver-fds`).
  `titanc` jobs started together by a parallel `make` would share the terminal,
  and their regions would overwrite each other.

Both forms use colour only when standard error is a terminal, `TERM` is not
`dumb`, and `NO_COLOR` is unset or empty. Following
[no-color.org](https://no-color.org), `NO_COLOR` turns off colour, not the live
region. The spinner and the finished marks (`✓`, `✗`) use Unicode on Linux and
macOS when the locale (the first non-empty of `LC_ALL`, `LC_CTYPE`, and `LANG`)
names UTF-8. Otherwise, and always on Windows, they are ASCII (`-\|/`, `ok`,
`FAILED`).

Only the `titanc` command reports progress. Code that uses the compiler as a
library, including language servers such as the one in vscode-titan, prints no
progress. Build automation that needs the output as it was before progress
reporting, for example to compare or parse standard error, should pass `-q`.

### Experimental Windows compilation

Windows library builds emit one DLL provider; they do not emit
a paired Titan archive. `--static` and selected Titan archive providers are
unsupported. Standalone builds emit a launcher in `bin` and an application DLL
under `lib/titan/0.6`. All use the SDK's controlled shared Lua DLL and matching
import library, rather than the Unix static `liblua.a` or an ordinary stock
Windows Lua build. See [Windows loading and launchers](binary-compatibility.md#experimental-windows-loading-and-launchers)
for output names and runtime layout, and the [Windows build guide](../implementation/windows-build.md)
for the SDK and native dependency link requirements.

The Windows compiler honors `--jobs` and `TITAN_JOBS` like Linux and macOS:
independent generated-C object compilations run concurrently up to that bound;
see [Windows native build parallelism](../implementation/windows-build.md#native-build-parallelism).
The Windows default C command is `clang.exe`; `CC` overrides it.

Configured tool commands and flags keep Titan's small shell-word grammar:
whitespace, single/double quotes, and backslash escapes. They do not expand
environment variables or interpret shell operators. For Windows paths in these
settings, quoted forward-slash spelling avoids ambiguity: set `CC` to the value
`"C:/native tools/clang.exe"`, including its double quotes. The first word must name a native `.exe` or
`.com`; an extensionless name selects `.exe`. Batch/PowerShell wrappers are
unsupported as implicit tool commands. Bare names use Windows `SearchPathW`
lookup; explicit paths select that exact native image. A native executable wrapper may precede
the compiler. Windows command arguments must be valid UTF-8 without line breaks, and the
initial shell transport has a conservative 8191-byte rendered-command limit. Native links
pass their compiler and linker arguments in a temporary response file (`@file`) beside the
output, so the number or length of object paths does not count against this limit; the
configured `CC` command and the response-file path stay on the command line.
Explicit `\\?\` executable paths are unsupported by this transport; use an
ordinary fully qualified executable path. Filesystem metadata operations retain
their separate support for extended paths.

Windows remains experimental. Shared-folder change notifications are best
effort; guest-local folders are the supported watcher test boundary. A successful
tool invocation alone does not establish that a complete Windows compiler,
runtime, or shared-folder workflow has passed its platform tests.

## Where modules are found

The examples below use Unix paths. On Windows the same rules apply to `.dll`
files and `\`-separated directories; see the [Windows relocation
rules](../implementation/windows-build.md#relocation-and-native-library-loading).

* **Source modules** are looked up in the *source tree* — the directory
  given by `--tree`, defaulting to the current directory. In each source root,
  the folder main `P/B.titan` wins over flat `P.titan`; a selected folder's
  immediate regular `.titan` siblings are assembled as contributors. Each
  source file may have target variants such as `P.linux.titan`, and the
  compilation's target selects one file per logical filename; see [Target
  source selection](target-source-selection.md#precedence).
  Constituents are not directly importable as flat child modules, although a
  genuine deeper folder module remains legal. See
  [Folder modules](folder-modules.md#lookup-and-precedence) for the complete
  precedence and privacy rules. Generated
  `.c`/`.o` files are always written next to the source; the linked
  `.so`/`.a` provider pair lands relative to the compiler's working
  directory, as described above.
* **Compiled modules** are looked up along the [Titan path](#the-titan-path),
  a list of directories. For logical `a.b.c`, the compiler performs a complete
  pass over `a.so`, `a/b.so`, and exact `a/b/c.so` in every directory, then a
  complete pass over the corresponding `.a` paths; `--static` swaps those
  passes. A file in an earlier directory shadows the same relative candidate
  in later directories within its format, while an unrelated ancestor
  container can advance to a deeper candidate. Programs, Lua hosts, and
  dependencies selected from DSOs use the same candidates and shadowing rules
  at run time. See [Finding a compiled module in a
  provider](multi-module-libraries.md#finding-a-compiled-module-in-a-provider)
  for DSO claims and [Static compiled
  modules](static-compiled-modules.md#dependency-search) for archive
  precedence and metadata.

### The Titan path

A Titan path is a list of directories separated by `;`. Each entry is a
directory, not a `?` template, and empty entries are ignored. The path comes
from `TITAN_PATH_0_6` when that variable is set, otherwise from `TITAN_PATH`,
otherwise from the default. A variable that is set but empty searches nothing.
Two further spellings are recognized in a variable:

* `;;` inserts the default path at that position, so
  `TITAN_PATH_0_6='vendor/lib;;'` searches `vendor/lib` first and then the
  default directories.
* `!` stands for the directory of the running executable, after resolving
  symlinks. It is replaced once and literally: text that comes from the
  inserted default or from the directory itself is never expanded again.

The default depends on who searches:

| Searcher | `!` is the directory of | Default path |
| --- | --- | --- |
| `titanc`, at compile time | the Lua interpreter that runs `titanc` | `.;<root>/lib/titan/0.6` |
| compiled programs, Lua hosts, [independent Lua states](standard-library-lua.md#independent-lua-states), at run time | the program or host executable | `!;!/../lib/titan/0.6`, then the SDK fallback |

`<root>` is the Titan SDK root: `TITAN_ROOT` when that variable is set and
non-empty, otherwise the parent of the directory that contains the Lua
interpreter running `titanc`. `titanc --print-root` prints it. `PREFIX` owns
Lua and LuaRocks, while `ROCKS_TREE` owns the Titan SDK and standard modules;
the supported developer installation makes those paths equal, but the names
do not have inherently identical ownership.

The run-time default has no `.`: the working directory never supplies
providers to a program. A program at `/opt/app/bin/app` searches
`/opt/app/bin` and then `/opt/app/lib/titan/0.6`, and a plain `lua` at
`$PREFIX/bin/lua` searches `$PREFIX/bin` and `$PREFIX/lib/titan/0.6`, where the
standard library is installed. Deploy a program's dynamic providers in one of
those two directories, or select them with a Titan path variable.

When a run-time lookup has missed in every directory and the path was derived
from the default (no variable, or a variable containing `;;`), Titan tries the
installed SDK once more. With `TITAN_ROOT` set, that is
`<TITAN_ROOT>/lib/titan/0.6`. Otherwise Titan runs `titanc --print-root`, or
`<TITANC> --print-root` when the `TITANC` variable names another program,
without a shell, and uses `<printed root>/lib/titan/0.6`. `TITANC` is one
program name or path, not a command line with arguments. On Windows a name
without `\`, `/`, or `:` (including the default `titanc`) is looked up only in
the `PATH` entries, never in the current directory or the program's own
directory, with `.exe` appended when the name has no extension; a `TITANC`
path is used as given. The query runs with the program's environment minus
`LUA_INIT` and `LUA_INIT_5_5`, so a Lua startup hook cannot run inside it. Each
Lua state tries this at most once and remembers the result, even when no SDK
was found; a
failure adds a `no Titan SDK fallback: <reason>` line to the `require` or load
error. The fallback is skipped when it names a directory already on the path.
This lets an executable built into an output tree use the installed standard
library while `titanc` is on `PATH`. The program named by `TITANC` (or the
`titanc` found on `PATH`) must terminate; Titan waits for it without a time
limit. Deployed applications should not depend on the fallback.

Titan's own Lua build sets `LUA_ROOT` to `"!/../"` and expands `!` in
`package.path` and `package.cpath` to the directory of the running
executable: an interpreter at `<root>/bin/lua` searches
`<root>/bin/../share/lua/5.5` and `<root>/bin/../lib/lua/5.5`, where Titan's
support module `titan.so` is installed. Moving that tree preserves those default
module paths, and invoking Lua through a symlink still uses the actual
executable's location. Environment path overrides retain their ordinary Lua
precedence. LuaRocks configuration and installed command wrappers may still
contain absolute paths, so this module-path behavior alone does not make an
entire installed toolchain relocatable.

Standalone Titan executables keep Lua's default `package.path` and
`package.cpath` and use the run-time Titan path above for dependencies
selected from DSOs. A Windows launcher in `bin` finds its own application DLL
relative to itself in `../lib/titan/0.6`, which is also the second default
entry. No path from the Titan build environment is embedded in the program.

### Standard-library names

The standard-library names `coroutine`, `uv`, `async`, `timer`, `io`, `fs`,
`net`, `ssl`, `url`, `http`, `websocket`, `os`, `path`, `peg`, `string`, `test`, `lua`, `math`, `gc`,
`iteration`, `reflect`, `sqlite3`, `json`, `protobuf`, and `transfer` are parser
sugar for the qualified module names
`titan.coroutine`, `titan.uv`, `titan.async`, `titan.timer`, `titan.io`,
`titan.fs`, `titan.net`, `titan.ssl`, `titan.url`, `titan.http`, `titan.websocket`, `titan.os`, `titan.path`,
`titan.peg`, `titan.string`, `titan.test`, `titan.lua`, `titan.math`, `titan.gc`,
`titan.iteration`, `titan.reflect`, `titan.sqlite3`, `titan.json`,
`titan.protobuf`, and `titan.transfer`.

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
`require "titan.async"`). The public [low-level libuv binding](standard-library-uv.md)
is available through `import "uv"` or `require "titan.uv"`. It exposes explicit
loops, native owners, callbacks, and utility operations; importing it alone
does not create an async Runtime or install the Task bootstrap.

Lua's `require` reaches compiled Titan modules through Titan's package
searcher (see [Requiring a Titan
module](lua-interop.md#requiring-a-titan-module)). A plain Lua host first runs
`require "titan"`, which loads the support module
`<root>/lib/lua/5.5/titan.so` from Lua's default `package.cpath` and appends
the searcher to `package.searchers`; compiled programs and Titan-created Lua
states already have it. `require "titan.os"` then probes `titan.so`,
`titan/os.so` along the run-time Titan path, where the canonical DSO
`<root>/lib/titan/0.6/titan.so` claims it, checks the ABI, and invokes the
module's exact `luaopen_titan_os` entry. Default Titan imports select that same
physical file by validating the `titan.os` callable metadata; `--static`
prefers the paired self-describing `titan.a`. Installation creates no child
DSOs, Lua loader files, parent-level copies, symbolic links, or hard links. The
installer does not provide cross-version migration. `titan-uninstall` removes
all Titan rock versions in its selected tree through LuaRocks, then cleans
the exact external Titan SDK/provider files only if removal succeeds. Lua and
shared dependencies remain. Canonical paths are shared across rock versions,
so cleanup applies to the whole Titan installation in that tree.

## Static and dynamic linking

Module dependencies are resolved *compiled first*:

* If an imported module is found in a shared provider, the compiler recovers
  its callable type metadata and generated code **dlopens** that selected
  provider at run time. Loading checks its ABI and the declarations this
  consumer depends on. Unused exports and compatible private storage may
  change without rebuilding the consumer; see
  [Replacing shared-library dependencies](binary-compatibility.md).
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
  `titanc titan.uv` rebuilds the `titan/uv/` folder module (whose native main
  is `uv.native.titan`) while that module's own imports still resolve through
  the selected compiled-format order first.

`--source-first` changes ordinary dependency selection to prefer available
source. `--incremental` may reuse a selected source module's companion object;
it does not change source or binary search precedence.

`--static` is a preference rather than a static-only mode: a missing archive
can fall back to a DSO and then source, and the system linker is not passed
`-static`. See [Static compiled modules](static-compiled-modules.md) for the
full composition and transitive-owner rules.

This ordinary ordering is enough to keep the installed standard-library
provider from being displaced accidentally by source files in `./titan`.
Changing `TITAN_PATH` so the installed provider is hidden deliberately selects
a different module graph.

Ordinary libuv clients use the [public `uv` module](standard-library-uv.md).
They do not need a native header or direct C call to consume its compiled API.
The implementation's native loader fixture separately checks that a narrow C
probe can resolve bundled libuv symbols through the same lazy/global provider
loading used by other dependencies. Its C file owns the `uv.h` include; its
Titan source sees only the probe header and public `uv`. That packaging test is
not the client extension interface. See
[native provider linkage](ffi.md#native-provider-linkage) for the distinction.

A statically linked dependency is still a module of its own from Lua's point
of view. Once `main.so` has initialized an embedded `geom.point`, a Lua script
that `require`s `geom.point` in the same Lua state receives that same module
instance, with the same record/union/Interface identities and the same module
variables, without loading another file. Before any importer has initialized
it, `require "geom.point"` succeeds only if a provider on the Titan path claims
`geom.point` itself, such as `geom.so` or `geom/point.so`.

## Standalone executables

If exactly one of the modules given to `titanc` defines a function with
the exact signature

```text
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

The entrypoint places only the main module's `luaopen_*` function in
`package.preload`. Requiring main still performs the existing Titan
initialization recursion before `main` runs. After each generated module's
`_init` succeeds, that module publishes its own `luaopen_*` under its logical
name in the registry preload table, which `package.preload` aliases. Lua code
can then use ordinary `require`, or Titan code can use `titan.lua.require`, to
obtain the already initialized canonical module value; `require` also fills
`package.loaded`. This includes private static archive dependencies reached by
the initialization recursion. The generated module also registers a separate
native provider descriptor containing code pointers only.
[Independent Lua states](standard-library-lua.md#independent-lua-states) copy
matching loaders and descriptors, so their compiled dynamic dependencies can
resolve the copied code before searching for a provider file. Every module
still initializes its own state and bindings. Any compiled-in module outside
the entrypoint's initialization closure and an unused archive sibling remain
absent from its preload table.

After `luaL_openlibs`, the executable installs Titan's package searcher. It
does not change Lua's `package.path` or `package.cpath`, embeds no build-time
path, and starts no process at startup: dependencies selected from DSOs, and
any compiled module the program `require`s, are found along the run-time
[Titan path](#the-titan-path). Deploy the standard provider and other
providers in the executable's directory or in `../lib/titan/0.6` next to it,
or set `TITAN_PATH_0_6`; build with `--static` to link archive providers
instead. `args[1]` onward
contain only the user-supplied arguments; index 0 is absent and the executable
name is not stored. Therefore `#args` is the argument count. The integer returned by
`main` becomes the process exit status; an uncaught run-time error
prints `<program name>: <error message>`, `stack traceback:`, and
tab-indented unified traceback frames through the Titan `main` frame to
standard error, then exits with a failure status. The synthetic Lua
bootstrap is not shown (see [Error handling](error-handling.md)).

Before it loads the main module, the generated entrypoint publishes the
process's original `argc` and `argv`. If a transitive import initializes
`titan.async`, its initializer calls public `uv.setup_process_args()`. That
helper calls libuv's `uv_setup_args` once and returns its possibly replaced
argument vector to the entrypoint before the `args` Array is built. Importing
`titan.uv` alone applies no startup policy; an explicit low-level caller may
call the helper while the original entrypoint argument contract is available. This startup contract is also why
[`os.exepath`](standard-library-os.md#directories-and-host-identity) is
available in compiled Titan programs but not when the standard module is
loaded by a Lua or other embedding host.

```titan
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

This section describes Linux and macOS. On Windows, Titan's controlled Lua DLL
is built from unmodified upstream sources with `-DLUA_BUILD_AS_DLL` and
linked with `-Wl,--export-all-symbols`, so that Lua's internal functions and
data are exported; a stock Lua 5.5.1 DLL built the same way can host Titan
modules. See the [Windows user guide](windows-build.md#the-lua-dll-and-c-helpers) and the
[controlled Lua DLL and its SDK](../implementation/windows-build.md#one-controlled-lua-dll-and-its-sdk).

Compiled Titan modules support the stock Lua loader; provider loading does
not require patched `dlopen` flags. Titan's own Lua build separately patches
`loadlib.c` to resolve module paths from the running executable, and its Unix
targets compile the Lua sources with `-fPIC` by default (for a stock Lua tree
that Titan links, see [A stock Lua tree](installation.md#a-stock-lua-tree)).
Each DSO and executable links the matched `liblua.a`;
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

A stock interpreter needs two things: Titan's support module on its
`package.cpath`, so that `require "titan"` installs the package searcher, and
the provider directories on the Titan path. A stock Lua does not expand `!` in
its own Unix paths, so name the support module's directory explicitly:

```sh
export LUA_CPATH_5_5="$ROCKS_TREE/lib/lua/5.5/?.so;;"
export TITAN_PATH_0_6="$ROCKS_TREE/lib/titan/0.6;;"
lua -e 'require "titan"; assert(require("titan.string"))'
```

Titan itself computes `!` in Titan paths from the running interpreter, so
`TITAN_PATH_0_6` can be omitted when that interpreter lives in
`$ROCKS_TREE/bin`; `TITAN_ROOT="$ROCKS_TREE"` also works, through the SDK
fallback. Do not add `$ROCKS_TREE/lib/titan/0.6` to `package.cpath`: Lua's
own C searchers run before Titan's searcher and would open the provider
without its ABI check. The bundled direct-libuv extension contract works the
same way: `require "titan.uv"` loads the shared `titan.so` provider through
the searcher, which maps it with global symbol visibility before invoking the
exact native entry. Titan still targets the exact Lua 5.5 runtime ABI and
internals; using the stock loader does not make a module compatible with
another Lua version or configuration.
