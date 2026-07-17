# Multi-module libraries

Titan keeps a module's *logical identity* separate from the shared library
that physically provides its native symbols. A single `titanc` invocation can
compile several related modules into one DSO while every module retains its
own interface, state, initialization, and Lua entry point.

For example, given:

```text
a/b/left.titan       # logical module a.b.left
a/b/right.titan      # logical module a.b.right
```

this library-mode invocation:

```sh
titanc a.b.left a.b.right
```

produces one object and one generated Lua loader (or *shim*) for each logical
module, but only one shared library:

```text
a/b/left.c
a/b/left.o
a/b/left.lua
a/b/right.c
a/b/right.o
a/b/right.lua
a/b.so
```

There is no `a/b/left.so` or `a/b/right.so`. Both Lua loaders find the
physical provider `a.b` (`a/b.so`), then call their own exact native entry:

```text
a/b/left.lua  -> a/b.so -> luaopen_a_b_left
a/b/right.lua -> a/b.so -> luaopen_a_b_right
```

The ordinary single-module case is the smallest instance of the same model.
`titanc foo.bar` produces `foo/bar.c`, `foo/bar.o`, `foo/bar.so`, and
`foo/bar.lua`; the logical module and physical provider both happen to be
`foo.bar`.

## Choosing the provider

When no requested module defines [`main`](functions.md#standalone-programs-main),
`titanc` derives one provider from the requested command-line roots. It
deduplicates the roots, splits their names into dotted components, and takes
their longest common sequence of complete components:

| Requested roots | Provider | Shared library |
| --- | --- | --- |
| `foo` | `foo` | `foo.so` |
| `foo.bar` | `foo.bar` | `foo/bar.so` |
| `foo.left foo.right` | `foo` | `foo.so` |
| `foo.bar.left foo.bar.right` | `foo.bar` | `foo/bar.so` |
| `foo foo.bar` | `foo` | `foo.so` |
| all seven `titan.*` standard roots | `titan` | `titan.so` |

The comparison is component-based: `foo.bar` and `foo.baz` share `foo`, but
`foo` and `foobar` share no module component. Unrelated roots are therefore an
error before code generation:

```text
cannot link modules into one shared library: 'foo' and 'bar' have no common module prefix
```

Use separate `titanc` invocations when unrelated roots should become separate
libraries. Transitive source dependencies do not affect the provider name.
They are linked into the selected provider and receive their own Lua loaders,
but making an unrelated dependency independently discoverable as a compiled
Titan module requires naming it as a root in a compatible invocation.

All linked modules must also have distinct generated C symbols. The compiler
checks this before generating C and reports both declarations when flattened
module/member names collide—for example, function `b_c` in module `a` and
function `c` in module `a.b`. Rename one of the modules or declarations to
build them into the same provider.

## Sharing an image does not merge modules

Each logical module in a provider still has its own:

* exported type interface and ABI marker;
* initializer and `luaopen_*` entry;
* private module state and once-per-Lua-state initialization guard;
* module variables, functions, record metatables, and nominal record names.

Loading one member does not initialize every sibling. Ordinary import edges
still determine initialization order, and unrelated siblings initialize only
when they are imported or required. A provider such as `a/b.so` does not
create a logical module `a.b`; it may contain only `a.b.left` and
`a.b.right`.

Within one Lua state, repeated imports and requires of a logical module return
that module's one instance. Different Lua states receive independent module
instances even though the operating system reuses the same mapped DSO. Record
identity remains the fully qualified logical record identity and the
per-state metatable for that record, not the provider prefix.

## Finding a compiled module in a provider

For an imported logical module, Titan probes every component prefix from
shallowest to exact. For `a.b.c`, the relative candidates are:

```text
a.so
a/b.so
a/b/c.so
```

The binary path comes from `TITAN_PATH_0_16` when set, otherwise `TITAN_PATH`,
otherwise the default `.;<root>/lib/titan/0.16`. In an override, `;;` inserts
that default at the same position. Search is **path-root first**: Titan walks
all candidates in the first path root before moving to the second root. Once
an earlier root contains a file at a relative candidate such as `a/b.so`, that
pathname shadows `a/b.so` in later roots even if the earlier file does not
contain the requested logical module. A clean nonclaim by an ancestor can
still advance to a deeper candidate such as `a/b/c.so`.

A candidate claims `a.b.c` when it exports either member of the requested
metadata pair, `a_b_c_abi` and `a_b_c_types`. Once claimed, validation is
terminal: both entries must exist, the ABI marker must be `0.16`, and the type
metadata must describe `a.b.c`. Broken, half-present, mismatched, or malformed
metadata is an error rather than permission to skip to another file. An
ancestor with neither entry is an unrelated nonclaim; an exact `a/b/c.so`
without the ABI marker remains an error. The first candidate that claims and
validates the logical module wins.

Generated Titan code records that selected relative provider and loads exactly
the same candidate at run time through the Titan binary path. Two imports from
one provider reuse its native handle but resolve their own mangled initializer
and function symbols.

Dependency selection remains binary-first. An ordinary `import` uses a valid
compiled provider before visible flat or folder source. A module named
explicitly on the `titanc` command line is source-first, which makes it a build
root even when an installed provider also contains it. Source dependencies
selected during that build are compiled and linked into the new provider;
compiled dependencies remain dynamic.

## Generated Lua loaders and ownership

Every logical source module linked into a library gets one generated `.lua`
loader at its logical path. This includes requested roots and source
dependencies. A [folder module](folder-modules.md) is already one logical
module, so it gets one loader for the module, never one per contributor. With
an external `--tree`, generated C stays beside the source while the provider
and logical loader paths are created below the compiler's working directory.

Generated loaders begin with:

```lua
-- Generated by titanc; do not edit.
```

The compiler may replace a file with that exact generated ownership banner.
It refuses to overwrite any other `.lua` file and checks all loader
destinations before changing C, object, DSO, or loader output. Loader files are
published only after the shared library has linked and validated successfully.

At run time a loader:

1. finds its physical provider name through `package.cpath`;
2. obtains Titan's native support table with `require "titan"`;
3. maps or promotes the provider with `RTLD_LAZY | RTLD_GLOBAL` through the
   support table's internal loader; and
4. calls the logical module's exact `luaopen_*` entry.

The provider cache canonicalizes its pathname, so relative and absolute
spellings in one Lua state share a handle. The exact logical module remains
cached by Lua's ordinary `require` machinery. A stock Lua 5.5 host needs both
the generated loaders on `package.path` and the provider on `package.cpath`.
Titan's installed Lua configures those paths for the standard library.
`package.cpath` is independent of Titan's compile-time binary path; a Lua
loader does not silently fall back to the provider selected by `TITAN_PATH`.
Install one canonical provider for an ABI, or explicitly put the intended
output root first in `package.cpath` when running checkout and fixture builds.

The initial `require "titan"` is an ordinary eager/local Lua C-module load.
For a different provider, the logical loader performs its first native mapping
with lazy/global flags. For the standard library's own `titan.so`, it performs
a second native open of the same canonical image, promoting the already loaded
support image into the global namespace before resolving `luaopen_titan_*`.
Bare `require "titan"` still returns only the support table and does not
initialize any `titan.*` module.

## Reserved `titan` name

The bare logical module name `titan` is reserved for the Lua support table
used by generated loaders. A library build rejects a source module named
exactly `titan`, including a transitive source dependency, and never generates
a top-level `titan.lua`.

A *physical* provider named `titan` is valid. Its DSO must also contain the
native support entry `luaopen_titan` with both internal loading functions; the
compiler validates that contract before publishing `titan.so` or any loaders.
The standard library is the canonical provider with this name.

## Compiled compatibility

This provider contract is the compiled-module ABI 0.16 boundary. A 0.15
consumer recorded only an imported module's exact child-DSO pathname and
cannot discover a shallower 0.16 container, even though the per-module type
metadata and native call signatures did not otherwise change. Rebuild Titan
modules together with their 0.16 runtime and use the 0.16 binary path; the
installation does not create compatibility child copies. An exact-path 0.16
module remains valid because the exact logical DSO is still the final prefix
candidate.

## Standalone programs

Executable mode is unchanged. If exactly one requested source module declares
the exact `main(args: {string}): integer` entry, Titan links the source closure
into one executable. It does not derive a library provider and emits neither a
DSO nor generated Lua loaders. Unrelated requested roots are consequently
legal in one program.

## The standard-library provider

Titan's complete installed standard library is the production example of this
model. One container:

```text
$ROCKS_TREE/lib/titan/0.16/titan.so
```

contains the native support entry plus the independent logical modules
`titan.coroutine`, `titan.uv`, `titan.async`, `titan.timer`, `titan.fs`,
`titan.net`, and `titan.os`. Their generated logical loaders live at:

```text
$ROCKS_TREE/share/lua/5.5/titan/coroutine.lua
$ROCKS_TREE/share/lua/5.5/titan/uv.lua
$ROCKS_TREE/share/lua/5.5/titan/async.lua
$ROCKS_TREE/share/lua/5.5/titan/timer.lua
$ROCKS_TREE/share/lua/5.5/titan/fs.lua
$ROCKS_TREE/share/lua/5.5/titan/net.lua
$ROCKS_TREE/share/lua/5.5/titan/os.lua
```

The image is also the installation's one complete libuv provider. There are
no production child DSOs, aliases, symbolic links, hard links, or Lua-facing
copies. `require "titan.async"` and `import "async"` still select the same
logical module and state; only their physical provider has been combined.
