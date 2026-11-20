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

Four boundaries keep this mechanism predictable:

1. **Visibility is direct, not transitive.** If `middle` writes `import "owner.titan"` and `consumer` imports `middle`, `consumer` gains no access to `owner`'s locals unless `consumer` also writes `import "owner.titan"`.
2. **C header environments flow transitively across `.titan` imports.** Every source module's `foreign import` directives and `foreign type` typedefs are inherited by explicit `.titan` importers, so private collaborating APIs can pass C types without repeating headers. Ordinary and binary imports never inherit C headers.
3. **Compiled providers and Lua stay public-only.** Neither `.so`/`.a`/`.dll` imports nor Lua's `require` can observe `local` declarations.
4. **Libraries cannot collaborate privately across the installed source fallback.** Explicit `.titan` imports are for authored source collaboration under `--tree` (or inside applications and `--test` builds). A library build (including plain non-`main` `-c`) rejects an explicit `.titan` import that resolves from the read-only implicit installed SDK fallback `<root>/lib/titan/0.6`; use an ordinary public `import` or include that source in an authored `--tree` checkout.

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

Compiled providers (`.so`, `.a`, or `.dll`) are searched along a semicolon-separated list of directories taken from `TITAN_PATH_0_6` (or `TITAN_PATH`), where `;;` inserts the default path and `!` expands to the running executable's directory. At compile time the default is `.;<root>/lib/titan/0.6`; at run time it is `!;!/../lib/titan/0.6` followed by the SDK fallback (never the current working directory). Positional `titanc` build roots resolve only from authored `--tree` roots (default `.`), never from the implicit installed source fallback; ordinary `import` statements inside an authored root search authored `--tree` roots first and then fall back to the read-only implicit SDK root `<root>/lib/titan/0.6` on both native and browser targets (requiring `-o`/`--output` if an installed source is selected).

For complete `titanc` flags and environment variables, provider search rules, `--static` archive linking, multi-module bundling, shared-library binary compatibility, `--incremental` and `-c` separate compilation, build profiles, stock Lua hosting, and `--coverage`, see [Appendix B: The `titanc` Toolchain, Linking, and Coverage](toolchain.md). For Windows DLL providers and launchers, see [Appendix A.2: Installing and Using Titan on Windows](windows-build.md).

## Packaging and distributing modules with LuaRocks

Installing Titan places `titan-install` and `titan-uninstall` beside `titanc` in the tree's `bin/` directory (`titan-install.bat` and `titan-uninstall.bat` on Windows). A module rock stages only its final library files under `$(PREFIX)/dist/` and invokes `titan-install --path "$(PREFIX)"` from its format `3.0` `post_install` hook so other Titan projects—and, for compiled native providers, Lua programs—can load the module without extra search paths. No Makefile is required.

### A complete minimal package

Choose a lowercase LuaRocks package name (`titan-cui`) and a logical Titan module name (`cui`, or a dotted prefix such as `cui.box` and `cui.text`). Neither the rock name nor Lua's `package.cpath` changes Titan's binary lookup: provider filenames always follow the logical module name or longest common dotted prefix.

Illustrative layout (ignore `/build/` and `.titan-ls/` in `.gitignore`):

```text
titan-cui/
  titan-cui-0.1.0-1.rockspec
  src/
    cui.titan
```

Write `titan-cui/src/cui.titan` without `main` so `titanc` builds a library provider (for native library tests, see [Testing standard library](standard-library-test.md)):

<!-- doc-check: file=titan-cui/src/cui.titan -->
```titan
local strings = import "string"

function box(text: string): string
  local edge = strings.rep("=", #text + 4)
  return edge .. "\n= " .. text .. " =\n" .. edge
end
```

Write `titan-cui/titan-cui-0.1.0-1.rockspec` (replace `source.url` and `tag` with your own release when packing a `.src.rock`):

<!-- doc-check: file=titan-cui/titan-cui-0.1.0-1.rockspec -->
```lua
rockspec_format = "3.0"
package = "titan-cui"
version = "0.1.0-1"
source = { url = "git+https://example.invalid/titan-cui.git", tag = "v0.1.0" }
description = { summary = "Minimal console UI box helper for Titan", license = "MIT" }
dependencies = { "lua ~> 5.5", "titan ~> 0.6" }
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

In a rockspec, `$(PREFIX)` is the *installing rock's private version directory* (for example `<tree>/lib/luarocks/rocks-5.5/titan-cui/0.1.0-1`), not your shell `$PREFIX`, the Titan SDK root, or `dist/`; `$(SCRIPTS_DIR)` is the tree's public `bin/`. In LuaRocks, `~>` is a prefix match (`"lua ~> 5.5"` matches `5.5.*`, and `"titan ~> 0.6"` matches Titan `0.6.*` releases; `TITAN_ABI_VERSION` is tracked independently of the package version).

Install from the checkout (`luarocks make` builds locally without fetching `source.url`):

<!-- doc-check: run -->
```sh
(cd titan-cui && luarocks make titan-cui-0.1.0-1.rockspec)
```

Verify from a separate directory `demo/` with no access to `titan-cui/src` or `titan-cui/build`. Write `demo/main.titan`:

<!-- doc-check: file=demo/main.titan -->
```titan
local cui = import "cui"
local io = import "io"

function main(args: {string}): integer
  io.print(cui.box("Titan"))
  return 0
end
```

Compile and run with no `--tree` and no `TITAN_PATH_0_6` override (dynamic, Unix `--static`, and Lua `require` for the compiled provider):

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

On Windows (no `--static` mode):

```cmd
titanc --output build --exe build\demo.exe main
build\demo.exe
```

Remove the module rock and its published files:

<!-- doc-check: run -->
```sh
titan-uninstall titan-cui
```

### Staging layout (`dist/`)

Build a single library module or a related canonical bundle in ordinary library mode with explicit logical roots (for example, Titan's standard library names all of its own roots; no other package embeds the standard library), producing only its own provider pair (`.so` and `.a` on Linux/macOS; `.dll` only on Windows) without incorporating external Titan dependencies. Declare package dependencies in the rockspec instead. `--static` is rejected on every final no-main library output, including canonical bundles (`-c --static` still compiles individual objects for a later executable, not a linked library). Dynamic/default applications may still fall back to an archive-only dependency or compile source, while on Linux and macOS a `--static` standalone or `--test` executable embeds the full reached Titan dependency closure from `.a` archives alongside source compiled in the application, with no fallback to shared Titan `.so` providers (a missing archive for an external prebuilt dependency not satisfied by application-compiled source is a build error). `--static` governs Titan module archives—it does not force `libc`, OS support, or external native libraries to link statically (nor forbid explicit linker flags that request it).

`titan-install --path "$(PREFIX)"` publishes regular files recursively from three namespaces under `$(PREFIX)/dist/`:

| Staged directory | Published destination | Contents |
| --- | --- | --- |
| `dist/modules/` | `<tree>/lib/titan/0.6/` | Compiled Titan providers (`cui.so` and `cui.a` on Linux/macOS; `cui.dll` only on Windows) or `.titan` source files, preserving logical subpaths (`cui/box.so` for `cui.box`). |
| `dist/include/` *(optional)* | `<tree>/include/` | Public C headers exported by the package (for example `.titan.h` or companion FFI headers); `include/titan/` is reserved for Titan SDK headers, so place package headers in a package-specific directory such as `dist/include/cui/`. |
| `dist/lib/` *(optional)* | `<tree>/lib/` | Optional native link inputs (such as C archives or Windows import `.lib` files); these are not stand-alone Titan providers. |

Stage only the exact final files—never copy `build/` wholesale, never stage compiler intermediates (`.c`, `.o`, `.titan/`, `.titan-links/`), `dist/bin/`, or symlinks, and never write directly into the SDK during the build. Relative paths under `dist/` must use portable ASCII ordinary file components (spaces are allowed; Windows reserved spellings, symlinks, and path or ASCII case aliases are rejected; this portable-entry naming rule does not apply to the absolute SDK or checkout path). You may alternatively recreate a fresh local `dist/` directory and declare `build.copy_directories = { "dist" }`, though staging into `$(PREFIX)/dist/modules` avoids carrying stale local files.

### Source-only modules

To distribute uncompiled `.titan` source files instead of prebuilt native providers, keep the same rockspec metadata, dependencies, and `hooks`, and replace only `build`. Either keep `src/cui.titan` and stage it into `$(PREFIX)/dist/modules/` during install:

```lua
build = {
   type = "command",
   install_command = 'mkdir -p "$(PREFIX)/dist/modules" && cp -p src/cui.titan "$(PREFIX)/dist/modules/"',
   platforms = {
      windows = {
         install_command = '(if not exist "$(PREFIX)\\dist\\modules" mkdir "$(PREFIX)\\dist\\modules") && copy /Y src\\cui.titan "$(PREFIX)\\dist\\modules\\cui.titan"'
      }
   }
}
```

Or check `dist/modules/cui.titan` directly into the repository (do **not** ignore `/dist/` in `.gitignore`) and copy it without shell commands:

```lua
build = {
   type = "none",
   copy_directories = { "dist" }
}
```

When compiling a consumer from an authored root (`main` below), positional `titanc` build roots—whether for a library, program, `-c`, explicit `--test`, or `--exe` build—resolve **only** from authored `--tree` roots (default `.`), never from the implicit installed source fallback (to compile a package itself, run from its source checkout with `--tree`, as the rockspec above does for `cui`, rather than naming an installed dependency as a positional root). Ordinary `import` statements inside a valid authored root search every authored root from `--tree` and then fall back to the read-only implicit SDK root `<root>/lib/titan/0.6` on both native and browser targets (on `--target browser`, `<root>/lib/titan/0.6` is searched for `.titan` source only, selecting `.browser.titan` or shared `.titan` variants normally; native providers there are never eligible):

```sh
titanc --output build --exe build/demo main
```

Whenever a build actually selects an installed `.titan` source through that implicit fallback—even when a library build only checks it—`-o`/`--output` is required so generated files stay under the caller's output tree and `titanc` neither writes nor locks inside the implicit SDK root; omitting `--output` fails with an error naming the module and asking for `--output DIR`. Builds that do not select an installed source keep their existing behavior.

A compiled library can depend on an installed source-only module without owning
it, and each consuming application supplies one chosen owner for that
dependency without rebuilding the library when the dependency's distribution
changes:

- **In a library build** (including plain non-`main`, non-`--test`, non-`--static` `-c` and `--source-first` when both a provider and an installed source exist): an ordinary public `import` resolved from `<root>/lib/titan/0.6` is checked for its public interface and public layouts and stays external—neither that module nor its private helpers or native dependencies enter the library provider. Native provider pairs and Windows DLLs carry only their authored `--tree` modules (plus any explicit non-Titan `-X` payloads); browser library archives likewise leave external installed sources outside the archive while retaining browser's preexisting separate archive composition for compiled browser dependencies. Even a private or initializer-only import of an installed source-only module is tracked automatically without adding it to the library's public API or requiring any extra manifest, config, or flag; wrapper libraries forward reached obligations without owning or baking a fallback path for forwarded binaries. Explicit `.titan` private collaboration (`import "dep.titan"`) remains strictly source-only and is rejected across that installed-source library boundary; use an ordinary public `import` or an authored `--tree` checkout instead.
- **Ordinary single-owner selection in consuming applications and `--test` builds:** For each dependency recorded by a reached logical member of an imported prebuilt library, `titanc` resolves the module by logical name through ordinary single-owner lookup for the active target and build mode—with no redundant `import` in the application, no unrelated private DSO scan, and no baked leaf-name substitution. For example, the compiler resolves `warehouse.counter` by logical name; a compatible `warehouse.so` can supply it even when no `warehouse/counter.so` exists. Eligible owners are an authored `--tree` or installed `<root>/lib/titan/0.6` source (compiled once into the application, requiring `--output` only when installed fallback `.titan` source is actually selected or on `--target browser`), a standalone compiled provider, a canonical common-prefix bundle claiming that logical name, or a member already carried by a selected provider:
  - **Default Unix** can elect a shared `.so` (loaded lazily through the application), an archive-only `.a` fallback (linked into the executable), or compile source once.
  - **Unix `--static`** accepts only `.a` archives or compiled source and rejects a DSO-only provider.
  - **Windows** elects a compiled `.dll` (loaded lazily through the application) or compiles source into the companion application provider DLL behind the launcher (no `--static`).
  - **`--target browser`** accepts only eligible WebAssembly `.a` archives or `.browser.titan`/shared `.titan` source (never native host binaries or dynamic loading).
  Every library shares the application's single chosen owner and its state lazily in written import order through the checked public ABI. Unreached siblings in a multi-module library impose no additional logical build demand. Missing all eligible owners fails the build naming both the referring library and the missing module; incompatible ABI or used public interfaces, malformed claimed providers, genuinely conflicting independent physical owners, and cross-boundary cycles remain build or load errors.
- **In editors and semantic tools:** Suppose a compiled library `via` imports the source-only `meter`, which in turn imports `units`. If `via` exposes `units.Quantity`, the editor can resolve `meter` by ordinary lookup—from authored or installed source, a compatible standalone provider, or a canonical common-prefix bundle (browser analysis uses eligible browser archives or browser SDK sources, never native binaries)—and follow its imports on demand to provide type information for `Quantity`, with no `--output` required and without eagerly checking purely private requirements that no exposed type needs. If no compatible provider or source for `meter` exists, install a compatible provider or add its source checkout to the project's source search roots.
- **Upgrades, existing applications, and bare Lua hosts:** An already-built application whose selected owner was compiled from source retains that app-compiled module and keeps running unchanged if the dependency on disk is later replaced by a compiled provider or removed. A later application rebuilt against the **same** prebuilt library can bind a compatible standalone or prefix-bundled compiled provider without rebuilding that library (within the same prerelease SDK/runtime family). Compatible implementation or private-dependency edits to an installed source require rebuilding only the consuming application; if a compiled intermediate library changes which external modules it requires, rebuild compiled libraries that forward those obligations (`--incremental` detects the change automatically). Ordinary prebuilt dependencies retain their normal compiled-provider fallback outside these recorded obligations. In a bare Lua `require` host (which has no Lua-side Titan compiler and no Titan application catalog), loading a prebuilt library **built against a dependency as installed source** first requires that dependency to be already initialized or natively preloaded in the Lua state; a Lua script can explicitly `require` an independently installed compiled provider first through the Titan searcher.

#### Depending on an installed source-only module from a compiled library

Assuming `titan-cui` is installed as a source-only rock from the recipe above (so `cui.titan` is present under `<tree>/lib/titan/0.6/`), another compiled library can import `cui` and publish without owning it. Write `titan-banner/src/banner.titan`:

```titan
local cui = import "cui"

function title(name: string): string
  return cui.box("Welcome, " .. name)
end
```

Write `titan-banner/titan-banner-0.1.0-1.rockspec`, declaring `"titan-cui ~> 0.1"` in `dependencies` and staging only `banner`'s own provider files:

```lua
rockspec_format = "3.0"
package = "titan-banner"
version = "0.1.0-1"
source = { url = "git+https://example.invalid/titan-banner.git", tag = "v0.1.0" }
description = { summary = "Banner helper built on source-only cui", license = "MIT" }
dependencies = { "lua ~> 5.5", "titan ~> 0.6", "titan-cui ~> 0.1" }
build = {
   type = "command",
   build_command = '"$(SCRIPTS_DIR)/titanc" --incremental --tree src --output build banner',
   install_command = 'mkdir -p "$(PREFIX)/dist/modules" && cp -p build/banner.so build/banner.a "$(PREFIX)/dist/modules/"',
   platforms = {
      windows = {
         build_command = '"$(SCRIPTS_DIR)\\titanc.exe" --incremental --tree src --output build banner',
         install_command = '(if not exist "$(PREFIX)\\dist\\modules" mkdir "$(PREFIX)\\dist\\modules") && copy /Y build\\banner.dll "$(PREFIX)\\dist\\modules\\banner.dll"'
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

Install `titan-banner` locally:

```sh
(cd titan-banner && luarocks make titan-banner-0.1.0-1.rockspec)
```

In a separate `app/` directory, write `app/main.titan` importing only `banner` (not `cui`):

```titan
local banner = import "banner"
local io = import "io"

function main(args: {string}): integer
  io.print(banner.title("Titan"))
  return 0
end
```

Compile and run dynamically or with Unix `--static`; `titanc` compiles `cui` once into `app`'s `--output` tree:

```sh
(cd app &&
  titanc --output build --exe build/app main &&
  ./build/app &&
  titanc --static --output build-static --exe build-static/app main &&
  ./build-static/app)
```

Each invocation prints:

```text
==================
= Welcome, Titan =
==================
```

Remove the dependent rock before the source-only rock it depends on:

```sh
titan-uninstall titan-banner
titan-uninstall titan-cui
```

### Publishing, packing, and upgrades

Keep three packaging concepts distinct:

1. **Source distribution (`.rockspec` / `.src.rock`):** A `.rockspec` describes how to fetch and build the package; running `luarocks pack titan-cui-0.1.0-1.rockspec` fetches the pinned `source` URL and tag and packs both the rockspec and sources into `titan-cui-0.1.0-1.src.rock`. To publish through your LuaRocks account, run `luarocks upload titan-cui-0.1.0-1.rockspec` (which packs a `.src.rock` by default; pass a prepacked `titan-cui-0.1.0-1.src.rock` only as the optional second argument—do not run `upload` during local verification). Consumers then run `luarocks install titan-cui` to build on their own platform.
2. **Package-built native provider:** Compiled during `luarocks install` (or `luarocks make`) and published to `<tree>/lib/titan/0.6/` (`cui.so`/`cui.a` on Unix, `cui.dll` on Windows), usable by both Titan `import` and Lua `require`.
3. **Installed source-only module:** `.titan` source published to `<tree>/lib/titan/0.6/`. Compiled libraries can typecheck against it and depend on it without owning it; each consuming Titan application or `--test` executable supplies one chosen owner through ordinary module lookup—compiling the source once (under `--output` whenever installed fallback source is selected or on `--target browser`) or binding a later compatible compiled provider or canonical prefix bundle without rebuilding the library (in bare Lua `require`, loading a library built against a dependency as source requires that dependency to be already initialized or natively preloaded first).

If you pack an already installed native rock with `luarocks pack titan-cui 0.1.0-1`, LuaRocks archives the retained `$(PREFIX)` directory (including `dist/`), and installing that `.rock` runs `hooks.post_install` without recompiling. Because `dist/modules/` sits outside LuaRocks' `lib` deployment, `luarocks pack` can name a native Titan rock `.all.rock`. Rename it to the architecture reported by `luarocks config arch` (for example `titan-cui-0.1.0-1.linux-x86_64.rock`) before sharing, and treat it as tied to the OS, CPU architecture, Lua version, Titan ABI, and build profile.

Each rock has one active published version. Before changing any published files, `titan-install` runs preflight checks and refuses the install if any destination collides with a foreign file, a Titan SDK-owned path (including the reserved `include/titan/` header subtree), or a protected `lib/` subtree (distinct from mid-copy I/O failures; there is no blanket transaction guarantee). Ownership is tracked strictly per physical destination file, with no compiler or DSO metadata introspection on publish: keep one rock per logical module or namespace and choose distinct author prefixes (the same convention that prevents Lua module rocks from masking each other), because two rocks shipping different physical representations of the same logical module—such as `.titan` source versus prebuilt `.so`/`.a`/`.dll` or flat versus folder files—are not rejected by logical name and can shadow one another. A succeeding same-version reinstall or upgrade retires only stale files owned by that rock and prunes shared directories only when empty.

### Uninstalling

Use `titan-uninstall titan-cui` to remove the active published version, or `titan-uninstall titan-cui 0.1.0-1` for an exact full rock version (removing an inactive older version leaves the active one intact, with no automatic switch-back). Plain `luarocks remove` has no uninstall hook and leaves published files behind; if you already ran it, follow with `titan-uninstall titan-cui` (or with its version) to clean up the remaining files (repeating cleanup for an absent rock is a no-op). When LuaRocks' dependency check fails, `titan-uninstall` leaves all published files untouched.

Running `titan-uninstall` with no arguments requests whole-Titan removal ([Uninstalling](installation.md#uninstalling)), which is likewise subject to LuaRocks' dependency check. On Windows, close consumers holding a module's mapped DLL before upgrading or removing it ([Windows](windows-build.md)). For the full ownership and preflight contract, see [Module rock publication and removal](../implementation/build-script-audit.md#module-rock-publication-and-removal).
