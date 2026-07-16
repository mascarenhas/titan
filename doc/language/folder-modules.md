# Folder modules

A logical Titan module may be written as one file or as a folder of source
files. Folder modules are useful when one module has a single public identity
but its implementation is too large for one source file. They do **not**
create submodules, file-private scopes, extra shared libraries, or a new kind
of import.

For a logical module name `M`, let `P` be `M` with dots replaced by directory
separators and let `B` be its final name component. The two source layouts are:

| Form | Canonical source |
| --- | --- |
| flat | `P.titan` |
| folder | `P/B.titan` |

For example, `graphics.scene` may be either
`graphics/scene.titan` or a folder whose main source is
`graphics/scene/scene.titan`:

```
graphics/
  scene/
    scene.titan       # required main source
    camera.titan      # contributor
    geometry.titan    # contributor
    notes.md           # ignored
    fixtures/          # ignored; collection is not recursive
```

Every immediate regular file ending in `.titan` beside `scene.titan`
contributes to `graphics.scene`. Other files and subdirectories are ignored.
The compiler does not recursively collect sources from nested directories.

## One module and one namespace

All contributing files form one module named `graphics.scene`. Their
declarations share one module scope, are checked together, and are emitted as
one C translation unit. A `local` top-level declaration is private to the
logical module, not to the file that contains it, so another contributor may
use it:

```lua
-- graphics/scene/scene.titan
function visible_objects(c: Camera): integer
    return count_visible(c)       -- local helper from geometry.titan
end
```

```lua
-- graphics/scene/geometry.titan
local function count_visible(c: Camera): integer
    -- ...
    return 0
end
```

Records, aliases, module variables, functions, methods, imports, and foreign
imports follow the logical module's ordinary
[visibility rules](modules.md#declaration-order-and-visibility) across files.
Public declarations from any contributor belong to `graphics.scene`; there is
no module named `graphics.scene.geometry` merely because `geometry.titan`
contributes source.

Duplicate declarations are diagnosed at the later declaration and include
the complete location of the earlier declaration, for example:

```
graphics/scene/geometry.titan:8:1: type error: duplicate declaration for bounds, previous one at graphics/scene/scene.titan:14:1
```

## Declaration order

The compiler constructs the logical declaration sequence deterministically:

1. declarations from the main source, in their written order;
2. declarations from contributors sorted by basename using numeric byte
   order, preserving the written order inside each file;
3. the main source's optional module initializer, last.

Numeric byte order compares the bytes of two basenames from left to right;
the first different byte decides, and a shorter prefix sorts first. It is
independent of the process locale. Thus ASCII `A.titan` sorts before
`a.titan`, `a.titan` before `aa.titan`, and UTF-8 names sort by their encoded
bytes. The main source always comes first even if its basename would sort
elsewhere.

This combined order is not a general visibility order. Records, aliases,
ordinary functions, methods, and record functions may refer across files
regardless of relative placement. An import in a later contributor is
available to a function signature, function body, record, or alias in the main
source. Records and their members are likewise order-independent: a method,
record function, `Rec.new(...)` call, or context-typed record constructor may
precede the written record declaration, even across contributors.

Module-variable declarations retain the one order-sensitive frontier. For
each such declaration, the combined order decides which imports and earlier
module variables are visible; records, aliases, and callable declarations are
visible module-wide. Thus an import in a later contributor is *not* available
to a module variable in the main source.

The combined order also decides which declaration is earlier for duplicate
diagnostics, orders serialized interface members and run-time module slots,
fixes module-variable initialization order, and remains the code-generation
order. A record declaration's synthesized `new` record function remains
beside that declaration in this sequence even though it is visible throughout
the module.

## Module initializer

A Titan module may end with one root `do ... end` initialization block. In a
folder module it may appear only at the end of the main source. Contributor
files may contain ordinary nested `do` statements inside functions and other
blocks, but may not contain a root module initializer.

Like any Titan block, that main initializer may have `catch` and `finally`
trailers. Those trailers remain part of the one initializer; they do not let a
contributor define another root initialization block.

```lua
-- graphics/scene/scene.titan
local initialized: boolean = false

do
    initialize_geometry()         -- may call a contributor-local function
    initialized = true
end
```

The initializer is placed after every contributor declaration and runs once
when the logical module is initialized in a Lua state, exactly like the
initializer of a flat module. There is still one module state and one
initializer.

## Lookup and precedence

Source roots are searched from left to right. Within one source root, the
folder main `P/B.titan` is tried before the flat source `P.titan`. Once a
folder main is selected, an error while reading, enumerating, parsing, or
checking that folder is an error in that module; the compiler does not fall
back to the flat file or a later source root.

Ordinary dependency lookup remains binary-first. If an exact compiled module
is present on the binary path, it is used before either source form. Modules
named explicitly on the `titanc` command line are source roots: they must have
source, and the folder-before-flat rule applies. This is why
`titanc titan.uv` rebuilds the source folder even when an installed
`titan/uv.so` exists, while an ordinary `import "uv"` may use that compiled
module.

### Contributors are not directly importable

Once a parent folder module exists, its immediate `.titan` constituents stay
private to that logical module. Suppose this layout exists:

```
pkg/
  service/
    service.titan
    worker.titan
```

Source lookup for `pkg.service.worker` must not reinterpret
`pkg/service/worker.titan` as a flat submodule. That lookup is blocked at this
source root and does not fall through to a later source root. The same rule
blocks the main source's apparent repeated-basename name
`pkg.service.service`.

A genuinely nested folder module is distinct and wins before the constituent
flat-file check:

```
pkg/
  service/
    service.titan
    worker.titan
    worker/
      worker.titan     # module pkg.service.worker
```

Here `import "pkg.service.worker"` selects
`pkg/service/worker/worker.titan`; the sibling `worker.titan` still belongs
only to `pkg.service`. A parent folder marker by itself does not reserve every
possible child name: if the requested immediate `.titan` constituent is
absent, normal lookup may continue to another source root. Exact compiled
modules are also unaffected because binary lookup happens before source
privacy is considered.

## Generated artifacts

The canonical main source controls where generated C and object files go.
The logical module name controls the shared-library and entrypoint paths.

| Form for `foo.bar` | Generated C/object | Shared library | Entrypoint | Executable |
| --- | --- | --- | --- | --- |
| flat `foo/bar.titan` | `foo/bar.c`, `foo/bar.o` | `foo/bar.so` | `foo/bar__entrypoint.c` | `foo/bar` |
| folder `foo/bar/bar.titan` | `foo/bar/bar.c`, `foo/bar/bar.o` | `foo/bar.so` | `foo/bar__entrypoint.c` | `foo/bar__main` |

The entrypoint and executable columns apply when the module declares Titan's
ordinary `main(args: {string}): integer`; that function may be declared in the
main source or a contributor. The `__main` suffix prevents the
folder program from colliding with its `foo/bar/` source directory and also
works when `--tree` points outside the current directory. Contributor files
never receive generated `.c`, `.o`, `.so`, or executable artifacts. For a
dotted module built from an external tree, the compiler creates the logical
output parent (such as `foo/`) in the current directory before linking.

## The standard `titan.uv` module

Titan dogfoods this layout in its libuv provider:

```
titan/uv/
  uv.titan          # shared imports/constants/state, bootstrap, initializer
  file.titan        # filesystem records, private FS constants, exported API
  os.titan          # OS/signal records and exported API
  process.titan     # process/pipe records and exported API
  runtime.titan     # runtime/byte records, Error, and version exports
  task.titan        # Task/timer records, methods, and exported API
  tcp.titan         # TCP/network records and exported API
```

The main source keeps the shared prelude, module state, bootstrap, and sole
initializer. Both exported and private record declarations live with their
semantic contributor implementations; contributor exports are ordinary
`titan.uv` members. These files are one logical module compiled with
`titanc titan.uv`. Both Titan imports and Lua `require "titan.uv"` continue to
load the single canonical `titan/uv.so`; no contributor is a separately
loadable module.

See [Modules](modules.md) for imports, module state, and the general
compilation model. The compiler-side assembly and artifact rules are detailed
in [Folder modules](../implementation/folder-modules.md) in the implementation
manual.
