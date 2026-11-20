# Modules and Program Structure

A Titan module is the unit of compilation, namespacing, and distribution. Its source is either a single `.titan` file or a folder module made of a canonical main file and sibling `.titan` contributors. Both layouts compile into one logical module.

Depending on what a module declares, `titanc` builds either a library provider (a shared library and static archive pair on Linux and macOS, or a DLL on Windows) or a standalone native executable when a module defines `main`. Other Titan modules depend on it statically through `import`; Lua code loads it dynamically through `require`.

```titan
local math = import "math"

record Circle
  const radius: float
end

const unit = Circle(1.0)
local tau = 2.0 * math.pi

function Circle:circumference(): float
  return tau * self.radius
end

function is_positive(circle: Circle): boolean
  return circle.radius > 0.0
end

function unit_circumference(): float
  return unit:circumference()
end
```

## Anatomy of a module

The top level of a module is a sequence of declarations, optionally followed by one final `do ... end` initialization block:

- **Imports:** `local alias = import "modname"`
- **Foreign header directives:** `foreign import "header.h"` ([Chapter 16](ffi.md))
- **Module variables:** `[local] [const] name [: type] [= expression]`
- **Functions and methods:** `[local] function name(...) ... end`, `[local] function Owner:method(...) ... end`, `[local] function Owner.fn(...) ... end`, and `[local] foreign function ...` ([Chapter 17](foreign-functions.md))
- **Type declarations:** `[local] type Name = Type`, `[local] record Name ... end`, `[local] union Name ... end`, `interface Name ... end`, and `foreign type Name = ...`

Every top-level `name = expression` is a declaration, not an assignment. Declaring the same value name twice is a compile error, even across different kinds such as a variable and a function:

```text
limit = 10
limit = 20          -- compile error: duplicate declaration for limit
```

Type aliases and Interfaces occupy a separate type-only namespace: they may share a name with a value declaration, but not with another alias, record, union, or Interface.

### Declaration order and visibility

A flat module's logical declaration order is its file order. A folder module's logical order places the main source first, then contributors sorted by logical filename, then the main initializer.

Most declarations are visible throughout the entire module regardless of order:

- **Types and callables are order-independent.** Records, unions, Interfaces, type aliases, ordinary functions, methods, static functions, and synthesized record or union constructors may refer to one another in any order, even across folder contributors.
- **Function and method bodies are order-independent.** Any body may refer to imports, module variables, types, and functions declared later in the module:

```titan
function scaled_default(): integer
  return double(base_count)
end

local base_count = 21

local function double(n: integer): integer
  return n * 2
end
```

- **Module variables have a deliberate frontier.** At each module-variable declaration, its type annotation and initializer see only *earlier* ordinary Titan imports and module variables. They still see every nominal type, alias, callable, synthesized constructor, and the complete module-wide `ffi` C environment. (A type alias can still name an import declared later, because aliases resolve in the placement-independent type pass.)

```text
origin = Point(0.0, 0.0)        -- ok: Point may appear later in the module

record Point
  x: float
  y: float
end

bad: geometry.Point? = nil      -- compile error: geometry is imported below
local geometry = import "geometry"
```

Logical order remains significant even where visibility is module-wide: it determines which declaration is reported as earlier in duplicate diagnostics, fixes module-variable initialization order, and fixes the order of a module's public members.

When a module loads into a Lua state—either directly through `require` or as a dependency of another module—initialization runs in a fixed sequence:

1. Imported modules initialize first.
2. Record, union, and Interface identities are created.
3. Module variables evaluate their initializers in declaration order.
4. Exported functions are published and the optional `do ... end` initializer runs.

A module initializes at most once per Lua state; subsequent imports or `require` calls return the same module instance.

### Built-in names and keyword members

Three readonly names are predeclared inside ordinary Titan code:

- `ffi` names the module's compile-time C namespace populated by `foreign import` directives. A declaration may shadow `ffi`, but assignment cannot replace it.
- `M` identifies the current module inside functions, methods, lambdas, and the module initializer. `M.member` reaches a module declaration—including local or keyword-named members—even when a local shadows its name, and `M.Type` selects a module type in annotations despite a local or generic shadow. With `foreign import "titan/ffi.h"`, `M as foreign *Udata` exposes the borrowed native module pointer.
- `L` is the current call's `foreign *lua_State` inside ordinary functions, methods, lambdas, and the module initializer ([Chapter 16](ffi.md)).

Source-defined `foreign function` bodies receive neither `L` nor `M`.

Top-level declarations, record fields, union variants and payload parts, Interface members, dot/colon member selectors, and named-call keys accept any ASCII identifier, including reserved keywords such as `end` or `type`. Local variables, parameters, and bare expression names require non-reserved identifiers. Use `M.end` to read a module member named `end`. The basic type names `boolean`, `integer`, `float`, `string`, and `value` are contextual identifiers rather than reserved words, so they may be used as ordinary variable or field names. See [Appendix C](grammar.md) for the complete keyword list.

## Module variables and initialization

A module-variable declaration has the form:

```text
[local] [const] name [: type] [= expression]
```

Every declaration requires a type annotation, an initializer, or both. Module variables do not use the `?` inference suffix; write an explicit Option type such as `local cache: string?` instead. With an initializer and no annotation, Titan infers the type. With an annotation, standard assignment conversions apply (`local ratio: float = 3` stores `3.0`).

A mutable or `const` module variable may omit its initializer only when its explicit type admits `nil` (`nil`, `value`, an Option `T?`, or a nullable C pointer). The slot starts as `nil` (or `NULL`).

Variables without `local` are exported: importing Titan modules and Lua callers can read them, and can write them when mutable. Variables with `local` stay private to the module (and direct `.titan` source collaborators).

### Const module variables

Adding `const` makes a module binding read-only:

```titan
const version = "0.6.0"
local const max_retries = 3
```

An initialized `const` module variable can never be assigned again, by Titan or by Lua.

An initializer-less `const` module variable must declare a nil-admitting type and may be assigned **only** directly inside its owning module's root `do ... end` initialization block:

```titan
local strings = import "string"

const banner: string?

function current_banner(): string
  return banner or ""
end

do
  banner = strings.upper("titan")
end
```

That write permission applies through nested blocks (`if`, loops, `do`) directly inside the root initializer, but does not carry into functions or lambdas called or created there, nor into any other module's initializer. The root initializer may assign the slot conditionally or more than once; once initialization finishes, the binding is permanently read-only for that Lua state. Because initialization may leave it unset, the type honestly remains optional or nullable.

### Initializer dependencies

Module-variable initializers run at module load time, not compile time. Both mutable and `const` initializers may use:

- literals and Array, Map, record, or union constructors;
- earlier visible imports—their variables, functions, constructors, and methods;
- `ffi` constants, variables, fields, indices, and C calls; and
- operators, casts, type tests, indexing, and calls built from those expressions.

```titan
local strings = import "string"
foreign import "limits.h"
foreign import "stdlib.h"

const max_int64: integer = ffi.LLONG_MAX as integer
local magnitude: integer = ffi.abs(-7)
local divider = strings.rep("-", 16)
```

An initializer **cannot** evaluate a reference to the current module's own variables, functions, or methods—even earlier or `const` ones—so initialization cannot observe partially constructed module state. Synthesized default record `new` and union-variant constructors are the sole exception because they only allocate and fill fields; a custom `Record.new` or a named own function used as a value is rejected.

```text
seed = 10
next_seed = seed + 1          -- compile error: reads own module variable
computed = compute()          -- compile error: calls own module function
callback = compute            -- compile error: reads own module function
```

Creating a callable without running it is allowed: an initializer may store a lambda, a bound own method (`Counter(1):current`), or an own record/union converted to an Interface, directly or inside containers and constructors. A lambda body may freely refer to the module's declarations because it runs only when called later:

```titan
local seed: integer?

record Counter
  start: integer
end

function Counter:current(): integer
  return self.start + seed
end

local readers = {function (): integer return seed end}
local first_reader = Counter(1):current

function read_first(): integer
  return first_reader()
end

do
  seed = 41
end
```

An initializer must not **expose** any own callable—a lambda, a bound own method, an Interface holding an own value, or a value of an own record/union that has methods—to an explicit or implicit call evaluated during initialization. Passing one as an argument to a call (even nested inside an Array, Map, or constructor), calling it directly, or passing it into a Map operation that could invoke a metamethod (`__index`, `__eq`, `__len`, or Map spread on a non-fresh Map) is rejected:

```text
-- Assume `sorter` and `registry` are imported modules:
a = Counter(1):current()                  -- compile error: invokes own method
b = sorter.sort({3, 1}, function (x: integer, y: integer): boolean
  return x < y
end)                                      -- compile error: passes lambda to call
c = registry.add({Counter(1):current})    -- compile error: nested in call argument
```

Fresh Map literals have no metatable, so indexing, `#`, spread, or equality between fresh Map literals does not trigger exposure. Likewise, if an initializer stores an own callable through an imported record's generated default constructor, the compiled consumer requires that the imported provider keeps its default generated `new` rather than replacing it with custom code.

### Module initialization block

When startup logic must read the module's own variables, call its own functions, or populate initializer-less `const` bindings, place one `do ... end` block after all declarations:

```titan
local initialized = false
const greeting: string?

local function build_greeting(): string
  return "ready"
end

function status(): string
  if not initialized then return "pending" end
  return greeting or ""
end

do
  greeting = build_greeting()
  initialized = true
end
```

A module has at most one root `do ... end` block, and it must be the final top-level construct. Like any Titan block, it may carry a `catch` clause. In a folder module, only the selected main file may define it, and it runs after every contributor's declarations.

## Importing modules

An `import` declaration binds another Titan module's exported interface to a local alias:

```titan
local io = import "io"
local math = import "math"
local strings = import "string"

function describe_circle(radius: float): string
  local area = math.pi * radius * radius
  return strings.format("area = %.2f", area)
end

function main(args: {string}): integer
  io.print(describe_circle(2.0))
  return 0
end
```

The module name is a string literal (single- or double-quoted; `import("math")` is also accepted). Import aliases are always `local` and are never re-exported—there is no chained `a.b.c` access through an intermediate module.

Module names are dot-separated components such as `geom.point` or `http.router`. Each component begins with an ASCII letter or underscore and continues with letters, digits, underscores, or hyphens. Dots map to directory separators (`geom.point` maps to `geom/point/point.titan` or `geom/point.titan`). A dotted name cannot end with the component `titan` (such as `example.titan`), because a trailing `.titan` in an import string always denotes an [explicit source import](#sharing-private-declarations-across-source-modules); the bare name `titan` is reserved for the Lua support module, while non-terminal segments such as `pkg.titan.child` are valid.

Through an import alias `geom`, the importing module accesses everything exported by `geom.point`:

- **Functions:** called directly (`geom.norm(p)`) or used as first-class values (`local f = geom.norm`) with stable source identity.
- **Variables:** read as `geom.origin`, and assigned when mutable (`geom.origin.x = 0.0`); exported `const` variables are read-only.
- **Records and unions:** referenced as types (`geom.Point`), constructed (`geom.Point(3.0, 4.0)` or `geom.Message.text("hi")`), and called for public static functions (`geom.Point.zero()`). Exported type aliases to records or unions preserve both type and constructor/static namespaces without creating a new runtime type.
- **Interfaces:** referenced in type positions (`geom.Shape`) and satisfied structurally at conversion sites; Interfaces are type-only and have no runtime namespace on the alias.

```text
-- geom/point.titan
record Point
  x: float
  y: float
end

origin = Point(0.0, 0.0)

function norm(p: Point): float
  return (p.x * p.x + p.y * p.y) ^ 0.5
end
```

```text
-- app/main.titan
local geom = import "geom.point"

function distance_from_origin(): float
  local p = geom.Point(3.0, 4.0)
  return geom.norm(p)
end
```

Module aliases are compile-time prefixes, not first-class values: `local g = geom` and `geom = nil` are compile errors. Importing the same module under two aliases refers to the same module instance.

**Circular imports are rejected at compile time.** If `a` imports `b` and `b` imports `a` (directly or transitively), `titanc` reports `circular reference to module` at the `import` that closes the cycle.

Titan uses `import` rather than Lua's `require` because the two operations have different semantics: `import` resolves a module's static interface at compile time and binds a compile-time namespace, whereas Lua's `require` searches paths dynamically at run time and returns a first-class value. When dynamic runtime loading of Lua, C, or Titan modules is genuinely required, use `lua.require` from [`import "lua"`](standard-library-lua.md) and convert the returned `value` into typed Titan data at the boundary.

### Standard-library short names

The 27 standard-library modules have short canonical import names in Titan that expand to `titan.<name>`:

| Domain | Titan short imports | Lua `require` names |
| --- | --- | --- |
| Strings, parsing, math, iteration | `string`, `peg`, `math`, `iteration` | `titan.string`, `titan.peg`, `titan.math`, `titan.iteration` |
| I/O, filesystem, OS | `io`, `path`, `fs`, `os` | `titan.io`, `titan.path`, `titan.fs`, `titan.os` |
| Concurrency & transfer | `async`, `timer`, `thread`, `coroutine`, `transfer` | `titan.async`, `titan.timer`, `titan.thread`, `titan.coroutine`, `titan.transfer` |
| Networking & Web | `url`, `net`, `ssl`, `http`, `websocket` | `titan.url`, `titan.net`, `titan.ssl`, `titan.http`, `titan.websocket` |
| Data, DB, reflection | `json`, `protobuf`, `sqlite3`, `reflect` | `titan.json`, `titan.protobuf`, `titan.sqlite3`, `titan.reflect` |
| Testing, GC, host bridges | `test`, `gc`, `lua`, `uv`, `browser` *(browser-only)* | `titan.test`, `titan.gc`, `titan.lua`, `titan.uv`, `titan.browser` |

Use the short spelling in Titan source (`local fs = import "fs"`, `local strings = import "string"` — pick an alias like `strings` when the short name is also a type word). In Lua code, always use the qualified name (`require "titan.string"`, `require "titan.os"`), which keeps Lua's standard `string`, `os`, `io`, `math`, and `coroutine` libraries untouched.

When the `.titan` source-import marker is combined with a short name, the marker is stripped before expansion: `import "uv.titan"` and `import "titan.uv.titan"` both request the source of logical module `titan.uv`.

## Multi-file folder modules

When one logical module grows too large for a single file, split it into a **folder module**. For a logical name `M` with path `P` (dots replaced by `/`) and final component `B`, the two source forms are:

| Layout | Canonical source |
| --- | --- |
| Flat module | `P.titan` |
| Folder module | `P/B.titan` plus immediate sibling `*.titan` files |

For example, `graphics.scene` can live in `graphics/scene.titan` or in a folder whose main source is `graphics/scene/scene.titan`:

```text
graphics/
  scene/
    scene.titan       -- required main source
    camera.titan      -- contributor
    geometry.titan    -- contributor
    notes.md          -- ignored
    fixtures/         -- ignored (collection is not recursive)
```

Every immediate regular `.titan` file beside `scene.titan` contributes to `graphics.scene`. Subdirectories and non-`.titan` files are ignored.

Folder modules do **not** create submodules, file-private scopes, or separate libraries:

- **One scope and one artifact:** All contributors share a single module namespace, compile into one logical C unit (or split parts of one module), and initialize as one module. A top-level `local` in `geometry.titan` is module-private, so `scene.titan` can call it directly.
- **Deterministic declaration order:** The compiler places the main file's declarations first, then each contributor sorted by locale-independent numeric byte order of its logical filename (so `A.titan` precedes `a.titan`, and `a.titan` precedes `aa.titan`), and finally the main file's optional `do ... end` initializer. Only the selected main file may define a root initializer.
- **Lookup precedence:** Within each `--tree` source root, the folder main `P/B.titan` wins over a flat `P.titan`. Once a folder main is selected, any parse or type error stops compilation rather than falling back to a flat file or later root.
- **Constituents stay private:** Once a directory contains a folder main (for any target), its immediate `.titan` siblings belong exclusively to that folder module and cannot be imported as flat child modules such as `graphics.scene.geometry` or `graphics.scene.scene`. A genuine nested folder module such as `graphics/scene/camera/camera.titan` remains independently importable as `graphics.scene.camera`.

The standard library uses this layout for several modules, including `titan.uv` (`titan/uv/uv.native.titan` and its contributors), `titan.async`, `titan.http`, `titan.json`, `titan.lua`, `titan.os`, `titan.protobuf`, and `titan.thread`. All 26 native standard-library logical roots are linked together into one combined `titan.so` / `titan.a` provider pair.

## Target-specific source files

Any logical source file `name.titan`—flat module, folder main, or folder contributor—may have **target variants** named `name.<label>.titan`. Five lowercase labels exist:

| Label | Applies to |
| --- | --- |
| `linux` | Linux |
| `darwin` | macOS |
| `windows` | Windows |
| `browser` | WebAssembly browser target (`--target browser`) |
| `native` | Every native OS host (Linux, macOS, Windows, or other native OS); never `browser` |

For each logical filename `name.titan`, the compiler selects the first existing regular file in its target's row:

| Target | Selection order |
| --- | --- |
| `windows` | `name.windows.titan`, `name.native.titan`, `name.titan` |
| `darwin` | `name.darwin.titan`, `name.native.titan`, `name.titan` |
| `linux` | `name.linux.titan`, `name.native.titan`, `name.titan` |
| Other native OS | `name.native.titan`, `name.titan` |
| `browser` | `name.browser.titan`, `name.titan` |

Key rules:

- **Target-only files need no default.** A module whose only file is `fs.native.titan` (or folder main `uv.native.titan`) exists on native targets and is absent on `browser`. A folder contributor with no applicable variant is simply omitted on that target.
- **Non-applicable files are ignored.** Files for other targets are never read, parsed, or scanned for imports or C headers.
- **Fallback happens only on absence.** Once a variant is selected, errors inside it are reported directly; the compiler never falls back to a less specific file.
- **Specificity stays within one family.** Within each `--tree` root, the folder-main family is tried before the flat-file family, before moving to the next root. An earlier root's `storage.titan` beats a later root's `storage.linux.titan`, and a selected folder `storage/storage.titan` beats a sibling flat `storage.linux.titan`.
- **Variant labels are strictly validated.** Stacked labels (`x.linux.native.titan`) and mis-cased labels (`x.Linux.titan`) are diagnosed whenever the compiler scans a folder module or `--test-dir` tree. A file named `linux.titan` has an empty base and is treated as an ordinary logical file (`linux.native.titan` is its `native` variant).

In a folder module, each contributor sorts by its logical filename with the label stripped (`ops.native.titan` sorts as `ops.titan`), so replacing a file with a target variant never changes declaration order:

```text
app/storage/
  storage.titan                 -- shared main
  backend-common.titan          -- shared contributor
  backend.native.titan          -- native implementation
  backend.browser.titan         -- browser implementation
  posix-helpers.native.titan    -- omitted on browser
```

A main variant replaces the default main completely and does not inherit its `do ... end` initializer; place shared startup work in a helper function inside a shared contributor and call it from each main's initializer.

Variant labels never enter logical module identity or generated filenames: `storage.linux.titan` compiles to `storage.c` and `storage.o`, and Lua still loads it as `require "app.storage"`. Diagnostics, tracebacks, and coverage reports name the actual selected physical file (`storage.linux.titan`). `--test-dir` automatically skips tests that have no applicable variant for the active target.

Select a non-default target with `titanc -T <label>` / `--target <label>` or `TITAN_TARGET` (the host OS label or `browser`; native cross-compilation between OSes is unsupported). For editor configuration, see [Browser type checking](browser-target.md#editor-type-checking); for full target flag details, see [Appendix B](toolchain.md).

Use whole-file target variants when implementations genuinely diverge. For small C constant or header differences on native platforms, prefer conditional preprocessor logic in a small C header behind `foreign import`.

## Sharing private declarations across source modules

An ordinary `import` exposes only public declarations, even when the dependency resolves to `.titan` source (including under `--source-first` or `--test`). To share `local` declarations across a group of collaborating source modules without exposing them to external callers or Lua, append `.titan` to the module name in the import string:

```text
local engine = import "example.engine.titan"
```

The `.titan` suffix is a compiler directive, not part of the logical module name (`example.engine`). It requires `example.engine` to resolve from source—failing if only a `.so` or `.a` provider exists—and grants access to its `local` declarations through that alias:

- local module variables (readable and, when mutable, writable);
- local functions and `local foreign function` designators;
- local records, unions, type aliases, fields, variants, methods, and constructors.

Local fields and methods on values of an imported nominal type work naturally (`state.hidden`, `state:advance()`), and visible local `const` fields or local methods can satisfy a public Interface at conversion sites inside the collaborating module.

Three boundaries keep this mechanism predictable:

1. **Visibility is direct, not transitive.** If `middle` writes `import "owner.titan"` and `consumer` imports `middle`, `consumer` gains no access to `owner`'s locals unless `consumer` also writes `import "owner.titan"`.
2. **C header environments flow transitively across `.titan` imports.** Every source module's `foreign import` directives and `foreign type` typedefs are inherited by explicit `.titan` importers, so private collaborating APIs can pass C types without repeating headers. Ordinary and binary imports never inherit C headers.
3. **Compiled providers and Lua stay public-only.** Neither `.so`/`.a` imports nor Lua's `require` can observe `local` declarations.

Because `.titan` names a logical module rather than a filename, `import "app.linux.titan"` requests logical module `app.linux`, not the Linux variant of `app`. Explicit source imports always select whichever target composition is active for the build.

## Documentation comments

Titan parses LDoc-style documentation comments for modules, top-level declarations, record fields, union variants, and Interface members, preserving them in compiled metadata for editor hover and completion (`vscode-titan`). Documentation comments have no effect on types or runtime behavior.

A doc comment starts with three or more hyphens (`---`), followed by `--` continuation lines (or uses Lua long-bracket form `--[[-- ... ]]`). The first sentence (ending in `.` or `?`, or the first line if none) is the summary; remaining lines form the description, and Markdown is allowed in both.

```titan
--- Integer counter utilities.
-- Small helpers for bounded non-negative counts.
-- @module counts

--- Add two counts.
-- @param left First count.
-- @param right Second count.
-- @return Their sum.
function add(left: integer, right: integer): integer
  return left + right
end

--- A readable counter.
interface Counter
  --- Read the current count.
  -- @return Current value.
  function read(): integer
end
```

Attachment and tag rules:

- **Module docs:** A leading comment containing `@module` documents the module itself (in a folder module, place it in the main file). A leading comment without `@module` attaches to the declaration immediately below it.
- **Paragraphs and termination:** A physical blank line ends a comment block; use an empty `--` line to separate paragraphs inside one block. A block attaches to the immediately following declaration separated only by whitespace.
- **Tags:** Lines starting with `@name` are preserved in source order (`@param`, `@tparam`, `@return`, `@treturn`, `@field`, `@raise`, `@see`, `@usage`, `@deprecated`, `@author`, `@license`, plus custom tags). Because Titan signatures already carry parameter names and types, type annotations in tags are optional.
- **Owner fallbacks:** An owner-level `@field name Description.` supplies field documentation when the field lacks its own comment block, and documented records or union variants supply docs for their synthesized constructors.
- **Standard-library `@usage` links:** Standard-library doc comments use `@usage <file.md>[#<anchor>]` relative to `doc/language/`, which editors resolve to the manual page.

Ordinary `--` comments, comments inside function bodies, and strings resembling comments are not collected as documentation.

## Compiling modules: `titanc`

Invoke `titanc` with dotted logical module names, not `.titan` file paths, and pass `-o <dir>` to keep generated files out of the source tree:

```sh
titanc -o out shapes                  # library provider: out/shapes.so and out/shapes.a
titanc -o out app.main                # standalone executable (when app.main defines main)
titanc -o out --test app.math_test    # native test executable
titanc --target browser -o out-web app.main   # WebAssembly browser build
```

For a single logical root `app.main` on Linux and macOS, `titanc -o out` produces:

| Source form | Generated C & object | Library provider pair | Executable |
| --- | --- | --- | --- |
| Flat `app/main.titan` | `out/app/main.c`, `.o` | `out/app/main.so`, `.a` | `out/app/main` |
| Folder `app/main/main.titan` | `out/app/main/main.c`, `.o` | `out/app/main.so`, `.a` | `out/app/main__main` |

Folder executables use the `__main` suffix so they do not collide with the `app/main/` source directory. Contributor files never produce separate C, object, or library outputs. Pass `--exe <path>` to place a standalone or test executable at an exact path, and `--tree 'src;tests'` to search multiple source roots in order.

Passing several non-`main` roots (such as `titanc -o out pkg.left pkg.right`) links them into one paired provider at their longest common dotted prefix (`out/pkg.so` and `out/pkg.a`).

### Standalone executables

When exactly one requested module defines `main` with the exact signature:

```titan
local io = import "io"

function main(args: {string}): integer
  io.print("received " .. #args .. " arguments")
  return 0
end
```

`titanc` links a standalone executable instead of a library provider. `args[1]` through `args[#args]` hold the command-line arguments (excluding the program name, so `#args` is the argument count), and the returned integer becomes the process exit status. Defining `main` in more than one requested module is a compile error.

If any transitively imported module initializes `titan.async` (for example `async`, `timer`, `fs`, `net`, `http`, `os`, `sqlite3`, or `thread`), the generated executable automatically schedules `main` as an async Task and drives the event loop until all Tasks finish. Pass `--no-uv-bootstrap` if `main` manages `async.loop()` sessions manually.

### Build output

`titanc` writes progress and diagnostics to standard error while reserving standard output for machine-readable queries (`--print-root`, `--print-ast`, `--print-c-objects`). Pass `-q` for diagnostics only or `-v` for full C tool command lines and `--incremental` decisions; see [Build output](toolchain.md#build-output) for terminal-mode and `NO_COLOR` rules.

### The Titan path

Compiled providers (`.so`, `.a`, or `.dll`) are searched along a semicolon-separated list of directories taken from `TITAN_PATH_0_6` (or `TITAN_PATH`), where `;;` inserts the default path and `!` expands to the running executable's directory. At compile time the default is `.;<root>/lib/titan/0.6`; at run time it is `!;!/../lib/titan/0.6` followed by the SDK fallback (never the current working directory). Source imports search every authored root from `--tree` (default `.`) and then fall back to the read-only installed module directory `<root>/lib/titan/0.6` on both native and browser targets; selecting an installed source through that fallback requires `-o`/`--output` so generated files stay out of the SDK.

For complete `titanc` flags and environment variables, provider search rules, `--static` archive linking, multi-module bundling, shared-library binary compatibility, `--incremental` and `-c` separate compilation, build profiles, stock Lua hosting, and `--coverage`, see [Appendix B: The `titanc` Toolchain, Linking, and Coverage](toolchain.md). For Windows DLL providers and launchers, see [Appendix A.2: Installing and Using Titan on Windows](windows-build.md).

## Packaging and distributing modules with LuaRocks

Titan distributes reusable libraries as ordinary LuaRocks packages. Installing Titan places two helper commands beside `titanc` in the tree's `bin/` directory (`titan-install` and `titan-uninstall`, or `titan-install.bat` and `titan-uninstall.bat` on Windows):

- A module rock builds its Titan library (or carries `.titan` sources), stages only the final files under `<rock-version-dir>/dist/`, and runs `titan-install --path "$(PREFIX)"` in its format `3.0` `post_install` hook.
- `titan-install` copies the staged files into the selected tree's canonical Titan directories so other Titan projects and Lua programs can import the module without extra search paths.
- `titan-uninstall ROCK [VERSION]` removes the rock through LuaRocks and then removes its published files.

### Package layout and library source

Give the LuaRocks package a lowercase rock name such as `titan-cui`, and choose a clean logical Titan module name such as `cui` (or a dotted prefix such as `cui.box` and `cui.text`). Neither the rock name nor Lua's `package.cpath` changes how Titan locates compiled providers: provider filenames follow the logical module name or longest common dotted prefix.

An illustrative package repository layout is:

```text
titan-cui/
  .gitignore
  titan-cui-0.1.0-1.rockspec
  src/
    cui.titan
  tests/
    cui_test.titan
  build/                       # generated by titanc (ignored, never staged whole)
```

Keep generated compiler outputs (`/build/`, `.titan-ls/`, and `/dist/` if you stage locally) in `.gitignore`. A library module omits `main` so `titanc` emits a provider instead of an executable. Write `titan-cui/src/cui.titan`:

<!-- doc-check: file=titan-cui/src/cui.titan -->
```titan
--- Minimal console UI formatting helpers.
-- @module cui

local strings = import "string"

--- A framed single-line text banner.
record Banner
  const title: string
  const border: string
end

--- Render the banner with matching top and bottom borders.
-- @return A multi-line bordered string.
function Banner:render(): string
  local width = #self.title + 4
  local edge = strings.rep(self.border, width)
  return edge .. "\n" .. self.border .. " " .. self.title .. " " .. self.border .. "\n" .. edge
end

--- Frame `text` with a single-character border (defaults to `"="`).
-- @param text The line to frame.
-- @param border Optional border string.
-- @return The rendered banner.
function box(text: string, border: string?): string
  local mark = border or "="
  return Banner(text, mark):render()
end
```

Add a native test module `titan-cui/tests/cui_test.titan`:

<!-- doc-check: file=titan-cui/tests/cui_test.titan -->
```titan
local cui = import "cui"
local test = import "test"

function test_box_formatting(context: test.Context)
  context:run("default_border", function(_)
    test.assert(cui.box("Titan") == "=========\n= Titan =\n=========")
  end)

  context:run("custom_border", function(_)
    local banner = cui.Banner("Hi", "*")
    test.assert(banner:render() == "******\n* Hi *\n******")
    test.assert(cui.box("Hi", "*") == banner:render())
  end)
end
```

Compile and run the native test suite before packaging (with `titanc` on `PATH`):

<!-- doc-check: run -->
```sh
(cd titan-cui &&
  titanc --incremental --test --tree "src;tests" --test-dir tests --output build --exe build/cui-tests &&
  ./build/cui-tests)
```

### Writing the rockspec

Use a format `3.0` rockspec with the `command` build backend and a `hooks.post_install` entry that calls `titan-install --path "$(PREFIX)"` (with a Windows platform override naming `titan-install.bat`). Write `titan-cui/titan-cui-0.1.0-1.rockspec`:

<!-- doc-check: file=titan-cui/titan-cui-0.1.0-1.rockspec -->
```lua
rockspec_format = "3.0"
package = "titan-cui"
version = "0.1.0-1"
source = {
   url = "git+https://github.com/example/titan-cui.git",
   tag = "v0.1.0"
}
description = {
   summary = "Minimal console UI formatting helpers for Titan",
   license = "MIT"
}
dependencies = {
   "lua ~> 5.5",
   "titan ~> 0.6"
}
build = {
   type = "command",
   build_command = '"$(SCRIPTS_DIR)/titanc" --incremental --tree src --output build cui',
   install_command = 'mkdir -p "$(PREFIX)/dist/modules" && cp -p build/cui.so build/cui.a "$(PREFIX)/dist/modules/"',
   platforms = {
      windows = {
         build_command = '"$(SCRIPTS_DIR)\\titanc.exe" --incremental --tree src --output build cui',
         install_command = '(if not exist "$(PREFIX)\\dist\\modules" mkdir "$(PREFIX)\\dist\\modules") && copy /Y build\\cui.dll "$(PREFIX)\\dist\\modules\\cui.dll"'
      }
   }
}
hooks = {
   post_install = '"$(SCRIPTS_DIR)/titan-install" --path "$(PREFIX)"',
   platforms = {
      windows = {
         post_install = '"$(SCRIPTS_DIR)\\titan-install.bat" --path "$(PREFIX)"'
      }
   }
}
```

Key rockspec rules:

- **LuaRocks `$(PREFIX)` and `$(SCRIPTS_DIR)`:** Inside a rockspec, `$(PREFIX)` is the installing rock's private version directory (for example `<tree>/lib/luarocks/rocks-5.5/titan-cui/0.1.0-1`), not your shell `$PREFIX`, not the Titan SDK root, not the working directory, and not `dist/` itself. `$(SCRIPTS_DIR)` is the selected tree's public `bin/` directory, where `titanc` and `titan-install` live. Pass `--path "$(PREFIX)"` unchanged; `titan-install` derives the destination tree from its own installation.
- **Version constraints (`~>`):** In LuaRocks, `~>` is a **prefix match**, not Ruby's pessimistic operator. `"lua ~> 5.5"` matches Lua `5.5.*`, and `"titan ~> 0.6"` matches any `0.6.*` release in Titan's `0.6` library ABI line while rejecting `0.7.0` and `0.7.0alpha`. By contrast, `"titan ~> 0.6.0"` locks to `0.6.0-*` only and rejects `0.6.1`. Combine with `>=` when a minimum patch release is needed (for example `"titan ~> 0.6, >= 0.6.0"`). For releases, pin `source` to a Git tag or versioned archive rather than a moving branch.
- **Staging into `dist/`:** `titan-install` publishes regular files recursively from three namespaces inside `$(PREFIX)/dist/`:

| Staged directory | Published destination | Contents |
| --- | --- | --- |
| `dist/modules/` | `<tree>/lib/titan/0.6/` | Compiled Titan providers (`cui.so` and `cui.a` on Linux and macOS; `cui.dll` only on Windows) or `.titan` source files, preserving logical subpaths (`cui/box.so` for `cui.box`). |
| `dist/include/` *(optional)* | `<tree>/include/` | Public C headers exported by the package (for example generated `.titan.h` or companion FFI headers). |
| `dist/lib/` *(optional)* | `<tree>/lib/` | Optional native link inputs (such as a C static archive or a Windows import `.lib`). These are not stand-alone Titan providers. |

Stage only the exact final files. Never copy `build/` wholesale, never stage compiler intermediates (`.c`, `.o`, `.titan/`, `.titan-links/`), never stage `dist/bin/` or symlinks, and never write directly into the SDK from `build_command` or `install_command`. On Windows, library mode emits only a provider DLL (`build\cui.dll`)—never treat a `.lib` file as a Titan provider—and `platforms.windows` commands must use native `cmd.exe` commands with explicit extensions and quoting. Alternatively, a build script may recreate a fresh local `dist/` directory and declare `build.copy_directories = { "dist" }`; writing directly into `$(PREFIX)/dist/modules` avoids stale files from earlier local builds.

Relative file paths under `dist/` must use portable ASCII ordinary file components (spaces are allowed; Windows reserved spellings, symlinks, and path or ASCII case aliases are rejected). This rule applies only to relative payload paths inside `dist/`, not to your checkout or SDK root.

### Installing and testing from a separate application

Install the local checkout with `luarocks make` (which builds directly from the current working directory without fetching `source.url`):

<!-- doc-check: run -->
```sh
(cd titan-cui && luarocks make titan-cui-0.1.0-1.rockspec)
```

Verify the installed package from a completely separate directory (`demo/`) that has no access to `titan-cui/src` or `titan-cui/build`. Write `demo/main.titan`:

<!-- doc-check: file=demo/main.titan -->
```titan
local cui = import "cui"
local io = import "io"

function main(args: {string}): integer
  io.print(cui.box(args[1] or "Titan"))
  return 0
end
```

Compile and run `demo` with no `--tree` and no `TITAN_PATH_0_6` override. On Linux and macOS, test both the default dynamic provider (`cui.so`) and `--static` (`cui.a`), as well as Lua's `require`:

<!-- doc-check: run -->
```sh
(cd demo &&
  titanc --output build --exe build/demo main &&
  ./build/demo &&
  titanc --static --output build-static --exe build-static/demo main &&
  ./build-static/demo &&
  lua -e 'require "titan"; print(require("cui").box("Titan"))')
```

Each invocation prints:

<!-- doc-check: expect=demo-banner -->
```text
=========
= Titan =
=========
```

On Windows, build and run the dynamic executable (Windows has no `--static` mode):

```cmd
titanc --output build --exe build\demo.exe main
build\demo.exe
```

### Source-only modules

A package may also ship `.titan` source files under `dist/modules/<logical/path>.titan` instead of (or without) precompiled native providers. For a repository that places `cui.titan` in `dist/modules/cui.titan`, LuaRocks' `none` build type copies `dist/` into `$(PREFIX)/dist/` without running a compiler at install time:

```lua
rockspec_format = "3.0"
package = "titan-cui"
version = "0.1.0-1"
source = {
   url = "git+https://github.com/example/titan-cui.git",
   tag = "v0.1.0"
}
description = {
   summary = "Minimal console UI formatting helpers for Titan (source-only)",
   license = "MIT"
}
dependencies = {
   "lua ~> 5.5",
   "titan ~> 0.6"
}
build = {
   type = "none",
   copy_directories = { "dist" }
}
hooks = {
   post_install = '"$(SCRIPTS_DIR)/titan-install" --path "$(PREFIX)"',
   platforms = {
      windows = {
         post_install = '"$(SCRIPTS_DIR)\\titan-install.bat" --path "$(PREFIX)"'
      }
   }
}
```

When a consumer compiles `demo/main.titan`, `titanc` searches every authored root from `--tree` (default `.`) and then falls back to the read-only installed module directory `<root>/lib/titan/0.6` on both native and browser targets (on `--target browser`, that directory is searched for `.titan` source only, selecting `.browser.titan` or shared `.titan` variants normally; native providers are never eligible for browser builds):

```sh
titanc --output build --exe build/demo main
```

Whenever a build actually selects an installed `.titan` source through that fallback, `-o`/`--output` is **required**: `titanc` writes generated C, objects, and headers under the consumer's output directory by logical module name and never writes or takes locks inside the installed SDK. Omitting `--output` when an installed source is selected fails with an error naming the logical module and asking for `--output DIR`; builds that do not select an installed source keep their existing behavior. Note that Lua's `require` loads compiled providers (`.so`/`.dll`), not uncompiled `.titan` source files.

### Source rocks, binary rocks, and upgrades

The primary distribution format for Titan module packages is a **source rock** (a rockspec pointing to a tagged release or checksummed source archive). Consumers install it with `luarocks install titan-cui`, which compiles against their own OS, CPU architecture, Lua installation, Titan ABI, and build profile.

If you pack an already installed rock with `luarocks pack titan-cui 0.1.0-1`, LuaRocks archives the retained `$(PREFIX)` contents (including `dist/`), and installing that `.rock` file runs `hooks.post_install` without recompiling. Because compiled Titan providers live in `dist/modules/` rather than LuaRocks' `lib` deployment directory, `luarocks pack` can name the output `titan-cui-0.1.0-1.all.rock` even though it contains platform-specific native binaries. Never distribute a prebuilt native Titan rock as `.all.rock`: rename it to the host architecture reported by `luarocks config arch` (for example `titan-cui-0.1.0-1.linux-x86_64.rock`) and treat it as specific to the OS, architecture, Lua version, Titan library ABI, and build profile.

`titan-install` enforces strict ownership boundaries:

- **One active published version per rock:** Reinstalling or upgrading `titan-cui` replaces the rock's previous published files and removes only stale files that belonged to `titan-cui`.
- **No silent overwrites:** `titan-install` checks destinations before writing and refuses to overwrite Titan SDK files, protected `lib/` subtrees, or files owned by another rock or the user.
- **Shared directories stay intact:** Cleanup removes directories only when they become empty, preserving sibling files from other packages.

### Uninstalling

Remove an installed Titan module rock with `titan-uninstall`:

<!-- doc-check: run -->
```sh
titan-uninstall titan-cui
```

Pass an explicit full rock version (`titan-uninstall titan-cui 0.1.0-1`) to target a specific version rather than the active published one. Removing an older retained, inactive version leaves the active published version intact (there is no automatic fallback to an earlier version).

Always use `titan-uninstall` rather than plain `luarocks remove`: LuaRocks has no uninstall hook, so `luarocks remove titan-cui` deletes the private rock directory while leaving published files under `lib/titan/0.6/`, `include/`, and `lib/` behind. If you already ran `luarocks remove titan-cui`, running `titan-uninstall titan-cui` (or `titan-uninstall titan-cui 0.1.0-1`) afterward cleans up the surviving published files; repeating cleanup for an already absent rock is a no-op. If another installed rock depends on `titan-cui`, LuaRocks refuses removal and `titan-uninstall` leaves all published files untouched.

Running `titan-uninstall` with **no arguments** removes Titan itself ([Uninstalling](installation.md#uninstalling)). On Windows, close running programs that have loaded a module's DLL before upgrading or uninstalling it ([Windows](windows-build.md)). For the full publication and ownership contract, see [Build and installation responsibilities](../implementation/build-script-audit.md#module-rock-publication-and-removal).
