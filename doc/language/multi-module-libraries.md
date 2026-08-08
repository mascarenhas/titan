# Multi-module libraries

Titan keeps a module's *logical identity* separate from the native provider
that physically carries its symbols. A single `titanc` invocation can compile
several related modules into one provider pair while every module retains its
own interface, state, initialization, and Lua entry point. Library mode
publishes matching `.so` and `.a` forms; this chapter concentrates on logical
grouping and the runtime DSO. See [Static compiled
modules](static-compiled-modules.md) for archive lookup, embedded metadata,
linking, and `--static`.

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
module, but only one provider pair:

```text
a/b/left.c
a/b/left.o
a/b/left.lua
a/b/right.c
a/b/right.o
a/b/right.lua
a/b.so
a/b.a
```

There is no `a/b/left.so` or `a/b/right.so`. Both Lua loaders find the
physical provider `a.b` (`a/b.so`), then call their own exact native entry:

```text
a/b/left.lua  -> a/b.so -> luaopen_a_b_left
a/b/right.lua -> a/b.so -> luaopen_a_b_right
```

The ordinary single-module case is the smallest instance of the same model.
`titanc foo.bar` produces `foo/bar.c`, `foo/bar.o`, `foo/bar.so`,
`foo/bar.a`, and `foo/bar.lua`; the logical module and physical provider both
happen to be `foo.bar`.

## Choosing the provider

When no requested module defines [`main`](functions.md#standalone-programs-main),
`titanc` derives one provider from the requested command-line roots. It
deduplicates the roots, splits their names into dotted components, and takes
their longest common sequence of complete components:

| Requested roots | Provider | Native outputs |
| --- | --- | --- |
| `foo` | `foo` | `foo.so`, `foo.a` |
| `foo.bar` | `foo.bar` | `foo/bar.so`, `foo/bar.a` |
| `foo.left foo.right` | `foo` | `foo.so`, `foo.a` |
| `foo.bar.left foo.bar.right` | `foo.bar` | `foo/bar.so`, `foo/bar.a` |
| `foo foo.bar` | `foo` | `foo.so`, `foo.a` |
| all seventeen `titan.*` standard roots | `titan` | `titan.so`, `titan.a` |

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
* module variables, functions, record/union/Interface metatables, and nominal
  names.

Loading one member does not initialize every sibling. Ordinary import edges
still determine initialization order, and unrelated siblings initialize only
when they are imported or required. A provider such as `a/b.so` does not
create a logical module `a.b`; it may contain only `a.b.left` and
`a.b.right`.

Within one Lua state, repeated imports and requires of a logical module return
that module's one instance. Different Lua states receive independent module
instances even though the operating system reuses the same mapped DSO. Nominal
identity remains the fully qualified logical record/union/Interface identity
and the per-state metatable for that nominal type, not the provider prefix.

## Finding a compiled module in a provider

This section specifies the callable metadata state machine for shared
providers. Static archives use the same logical component prefixes but carry
their metadata in object sections and run in a separate whole-format pass; see
[Static compiled modules](static-compiled-modules.md#dependency-search).

For an imported logical module, Titan probes every component prefix from
shallowest to exact. For `a.b.c`, the relative candidates are:

```text
a.so
a/b.so
a/b/c.so
```

The binary path comes from `TITAN_PATH_0_22` when set, otherwise `TITAN_PATH`,
otherwise the default `.;<root>/lib/titan/0.22`. In an override, `;;` inserts
that default at the same position. Search is **path-root first**: Titan walks
all candidates in the first path root before moving to the second root. Once
an earlier root contains a file at a relative candidate such as `a/b.so`, that
pathname shadows `a/b.so` in later roots even if the earlier file does not
contain the requested logical module. A clean nonclaim by an ancestor can
still advance to a deeper candidate such as `a/b/c.so`.

A candidate claims `a.b.c` when it exports either member of the requested
metadata pair, `a_b_c_abi` and `a_b_c_types`. Once claimed, validation is
terminal: both entries must exist, the ABI marker must be `0.22`, and the type
metadata must describe `a.b.c`. Broken, half-present, mismatched, or malformed
metadata is an error rather than permission to skip to another file. An
ancestor with neither entry is an unrelated nonclaim; an exact `a/b/c.so`
without the ABI marker remains an error. The first candidate that claims and
validates the logical module wins.

Generated Titan code records that selected relative provider and loads exactly
the same candidate at run time through the Titan binary path. Two imports from
one provider reuse its native handle but resolve their own mangled initializer
and function symbols.

Dependency selection remains compiled-first. An ordinary `import` uses the
preferred valid compiled provider before visible flat or folder source. A
module named explicitly on the `titanc` command line is source-first, which
makes it a build root even when an installed provider also contains it. Source
dependencies selected during that build are compiled and linked into the new
provider. A selected DSO remains dynamic; a selected static provider is direct
native input and its complete physical membership is carried into both new
provider forms. See [Static compiled
modules](static-compiled-modules.md#direct-and-dynamic-dependencies) for the
transitive-owner constraints.

## Generated Lua loaders and ownership

Every physical logical module published in a library DSO gets one generated
`.lua` loader at its logical path. This includes requested roots, source
dependencies, and logical modules carried from a selected static provider. A
[folder module](folder-modules.md) is already one logical module, so it gets
one loader for the module, never one per contributor. With an external
`--tree`, generated C stays beside the source while the provider and logical
loader paths are created below the compiler's working directory.

Generated loaders begin with:

```lua
-- Generated by titanc; do not edit.
```

The compiler may replace a file with that exact generated ownership banner.
It refuses to overwrite any other `.lua` file and checks all loader
destinations before changing C, object, provider, or loader output. Loader
files are published in the same recoverable transaction as the validated
provider pair, before the DSO commit point.

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

ABI 0.20 introduced two private user values on every Array proxy—backing and
construction-time Lua writer—and a fixed opaque brand upvalue plus final
strict generic-entry trailer on every Titan function closure. ABI 0.21
retained those representations while advancing the embedded Lua contract from
5.5.0 to 5.5.1. ABI 0.22 is the source-local `titan.uv`
surface/private-provider boundary: its serialized public schema and
reconstructible module-state prefix change while Lua 5.5.1 and the other 0.21
layouts remain unchanged. The current marker, `TITAN_PATH_0_22`, and
`lib/titan/0.22` namespace advance together. Ordinary DSO/archive metadata
validation rejects 0.21 before either side can exchange a value; there is no
compatibility adapter, migration, or cleanup path. A separately versioned 0.21
installation remains preserved prior-version state.

ABI 0.19 introduced serialized union/variant schemas and made the module-state
public prefix reconstruct public record and union static closures after
exported variables and top-level function closures. That preserved
first-class imported constructor/static identity, but its Arrays still had
one proxy user value and its non-exact Titan calls reused the coercive Lua
entry.

ABI 0.18 changed the standard-library archive/runtime contract: logical
objects began referring directly to callback trampolines promoted into the
runtime's external symbol contract and stopped referring to the retired
libuv/coroutine helpers. A provider and runtime therefore both had to be 0.18;
either direction of a 0.17/0.18 static pairing was incompatible.

ABI 0.17 introduced the canonical-proxy Array meaning: `{T}` is a proxy over
private dense-capacity backing storage, not an ordinary table. That semantic
break changed what the existing native Array pointer slots mean, along with
generated container code and Lua boundary checks, so 0.16 and 0.17 providers
could not be mixed. ABI 0.18 and 0.19 preserved its one-user-value proxy;
ABI 0.20 retained the canonical identity while adding the writer user value;
ABI 0.21 retained that representation, and ABI 0.22 retains it.

Historically, ABI 0.16 introduced prefix-container discovery: a 0.15 consumer
recorded only an imported module's exact child-DSO pathname and could not
discover a shallower 0.16 container. The installation creates no compatibility
child copies for either transition.

ABI 0.20 also introduced Interfaces. Serialized metadata carries each
Interface's nominal owner and declaration-order method signatures; each module
initializes its per-state Interface identities, and generated wrappers,
vtables, and method trampolines use the new layout. The same version therefore
covers the Interface, relation, Array-writer, and strict-function-entry changes
as one clean break. A 0.19 artifact has none of these Interface contracts and
is rejected rather than adapted.

## Standalone programs

Executable mode is unchanged. If exactly one requested source module declares
the exact `main(args: {string}): integer` entry, Titan links the source closure
into one executable. It does not derive a library provider and emits neither a
DSO nor generated Lua loaders. Unrelated requested roots are consequently
legal in one program.

## The standard-library provider

Titan's standard library is the seventeen-root production example of this
model. One
paired provider:

```text
$ROCKS_TREE/lib/titan/0.22/titan.so
$ROCKS_TREE/lib/titan/0.22/titan.a
```

contains the native support entry plus the independent logical modules
`titan.coroutine`, `titan.uv`, `titan.async`, `titan.timer`, `titan.io`,
`titan.fs`, `titan.net`, `titan.ssl`, `titan.url`, `titan.http`, `titan.os`,
`titan.peg`, `titan.string`, `titan.math`, `titan.lua`, `titan.iter`, and
`titan.gc`. Their
generated logical loaders live at:

```text
$ROCKS_TREE/share/lua/5.5/titan/coroutine.lua
$ROCKS_TREE/share/lua/5.5/titan/uv.lua
$ROCKS_TREE/share/lua/5.5/titan/async.lua
$ROCKS_TREE/share/lua/5.5/titan/timer.lua
$ROCKS_TREE/share/lua/5.5/titan/io.lua
$ROCKS_TREE/share/lua/5.5/titan/fs.lua
$ROCKS_TREE/share/lua/5.5/titan/net.lua
$ROCKS_TREE/share/lua/5.5/titan/ssl.lua
$ROCKS_TREE/share/lua/5.5/titan/url.lua
$ROCKS_TREE/share/lua/5.5/titan/http.lua
$ROCKS_TREE/share/lua/5.5/titan/os.lua
$ROCKS_TREE/share/lua/5.5/titan/peg.lua
$ROCKS_TREE/share/lua/5.5/titan/string.lua
$ROCKS_TREE/share/lua/5.5/titan/math.lua
$ROCKS_TREE/share/lua/5.5/titan/lua.lua
$ROCKS_TREE/share/lua/5.5/titan/iter.lua
$ROCKS_TREE/share/lua/5.5/titan/gc.lua
```

The DSO is also the installation's one complete dynamic libuv provider; in
bundled mode the archive carries the same private libuv object payload. Both
forms also carry the private, metadata-free LPegLabel objects used through
`titan.peg` by `titan.string` and `titan.url`, plus the llhttp objects and
narrow callback adapter used by `titan.http`. `titan.ssl` calls OpenSSL
directly; bundled mode carries its OpenSSL objects.
None of those private
archives or headers is an installed SDK library. There are
no production child DSOs, aliases, symbolic links, hard links, or Lua-facing
copies. `require "titan.async"` and `import "async"` still select the same
logical module and state; only their physical provider has been combined.
