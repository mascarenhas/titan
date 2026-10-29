# Multi-module libraries

Titan keeps a module's *logical identity* separate from the native provider
that physically carries its symbols. A single `titanc` invocation can compile
several related modules into one provider while every module retains its
own interface, state, initialization, and Lua entry point. Library mode
publishes matching `.so` and `.a` forms on Linux and macOS; this chapter
concentrates on logical grouping and the runtime DSO. See [Static compiled
modules](static-compiled-modules.md) for archive lookup, embedded metadata,
linking, and `--static`.

The paired-provider paths and archive examples below describe Linux and macOS.
Windows uses the same logical grouping with one DLL provider, without a paired
Titan archive or `--static` mode; see
[Windows loading and launchers](binary-compatibility.md#experimental-windows-loading-and-launchers).

For example, given:

```text
a/b/left.titan       # logical module a.b.left
a/b/right.titan      # logical module a.b.right
```

this library-mode invocation:

```sh
titanc a.b.left a.b.right
```

produces generated C and objects for each logical module, but only one
provider pair:

```text
a/b/left.c
a/b/left.o
a/b/right.c
a/b/right.o
a/b.so
a/b.a
```

Each module's primary object records which generated C files and objects
belong to that module. A module large enough to be
[split](build-profiles.md#split-modules) also has
`.priv.h`, `.part1.c`, `.part1.o`, and further numbered parts; the provider
pair links every one of its objects.

There is no `a/b/left.so` or `a/b/right.so`, and no Lua file is generated.
Lua's `require` finds the physical provider `a.b` (`a/b.so`) through Titan's
package searcher and calls each module's own exact native entry:

```text
require "a.b.left"  -> a/b.so -> luaopen_a_b_left
require "a.b.right" -> a/b.so -> luaopen_a_b_right
```

The ordinary single-module case is the smallest instance of the same model.
`titanc foo.bar` produces `foo/bar.c`, `foo/bar.o`, `foo/bar.so`, and
`foo/bar.a`; the logical module and physical provider both happen to be
`foo.bar`.

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
| all twenty-six `titan.*` standard roots | `titan` | `titan.so`, `titan.a` |

The comparison is component-based: `foo.bar` and `foo.baz` share `foo`, but
`foo` and `foobar` share no module component. Unrelated roots are therefore an
error before code generation:

```text
cannot link modules into one shared library: 'foo' and 'bar' have no common module prefix
```

Use separate `titanc` invocations when unrelated roots should become separate
libraries. Transitive source dependencies do not affect the provider name.
They are linked into the selected provider, but making an unrelated
dependency independently discoverable as a compiled Titan module, from Titan
or from Lua's `require`, requires naming it as a root in a compatible
invocation.

All linked modules must also have distinct generated C symbols. Callable names
encode the module/member and nominal/member boundaries, so function `b_c` in
module `a` and function `c` in module `a.b` remain distinct. The compiler still
preflights genuinely colliding flattened module protocol prefixes (including
`.`/`-` aliases) and cross-family protocol names, and reports both owners before
generating C.

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

The directories come from the [Titan path](modules.md#the-titan-path):
`TITAN_PATH_0_6` when set, otherwise `TITAN_PATH`, otherwise the default, which
is `.;<root>/lib/titan/0.6` for the compiler and `!;!/../lib/titan/0.6`
(followed by the SDK fallback) for programs and Lua hosts. In a variable, `;;`
inserts that default at the same position and `!` stands for the running
executable's directory. Search is **path-root first**: Titan walks
all candidates in the first path root before moving to the second root. Once
an earlier root contains a file at a relative candidate such as `a/b.so`, that
pathname shadows `a/b.so` in later roots even if the earlier file does not
contain the requested logical module. A clean nonclaim by an ancestor can
still advance to a deeper candidate such as `a/b/c.so`.

A candidate claims `a.b.c` when it exports either member of the requested
metadata pair, `a_b_c_abi` and `a_b_c_types`. Once claimed, validation is
terminal: both entries must exist, the ABI marker must be `2`, and the type
metadata must describe `a.b.c`. Broken, half-present, mismatched, or malformed
metadata is an error rather than permission to skip to another file. An
ancestor with neither entry is an unrelated nonclaim; an exact `a/b/c.so`
without the ABI marker remains an error. The first candidate that claims and
validates the logical module wins.

Generated Titan code records that selected relative provider and loads exactly
the same candidate at run time through the run-time Titan path. Two imports
from one provider reuse its native handle but resolve their own mangled
initializer and function symbols. Lua's `require` uses the same candidates and
claim rules (see [below](#loading-library-modules-from-lua)).

Ordinary dependency selection remains compiled-first. An ordinary `import` uses the
preferred valid compiled provider before visible flat or folder source. A
module named explicitly on the `titanc` command line is source-first, which
makes it a build root even when an installed provider also contains it. Source
dependencies selected during that build are compiled and linked into the new
provider. A selected DSO remains dynamic; a selected static provider is direct
native input and its complete physical membership is carried into both new
provider forms. See [Static compiled
modules](static-compiled-modules.md#direct-and-dynamic-dependencies) for the
transitive-owner constraints.

## Loading library modules from Lua

Lua code reaches every physical logical module of a library DSO, including
requested roots, source dependencies, and modules carried from a selected
static provider, with ordinary `require`. The lookup is done by Titan's
package searcher, which a plain Lua host installs by loading Titan's support
module first:

```lua
require "titan"                     -- installs the Titan searcher
local left = require "a.b.left"     -- searches the Titan path
```

Standalone Titan programs, [independent Lua states](standard-library-lua.md#independent-lua-states),
and thread children already have the searcher. `require "titan"` loads the
support module `<root>/lib/lua/5.5/titan.so` (`titan.dll` on Windows) through
Lua's ordinary `package.cpath`; it returns a small support table and does not
initialize any `titan.*` standard module.

For `require "a.b.left"` the searcher:

1. returns `a.b.left` if this Lua state already initialized it, for example as
   a dependency of another module, without opening another file;
2. uses a matching [native preload](standard-library-lua.md#independent-lua-states)
   registered by an initialized or copied module;
3. otherwise probes `a.so`, `a/b.so`, and `a/b/left.so` along the run-time
   Titan path with the candidate and claim rules above, checks the ABI marker,
   and calls the module's exact `luaopen_a_b_left` entry.

When nothing claims the module, the searcher adds its `no file '…'` lines to
Lua's usual `module 'a.b.left' not found` error. A provider that exists but
cannot be loaded, has half of the metadata pair, lacks the exact module's ABI
marker, or carries another ABI is an error instead of a miss. Because `.` and
`-` both become `_` in native names, `a.b-c` and `a.b_c` share one entry name;
the entry checks the requested name whenever a searcher loads it from a file,
and fails with `module name mismatch: requested 'a.b_c', provider defines
'a.b-c'` rather than initializing under the wrong name. Lua's `package.preload` may
still alias an entry deliberately: `package.preload["alias"] = loader` makes
`require "alias"` return that module under its own logical identity.

Lua's own searchers run before Titan's. Do not put Titan provider directories
on `package.cpath`, where Lua's C searcher would open a provider without the
checks above, and remove `.lua` files from earlier pre-release builds
(`a/b/left.lua` and friends): Lua's source searcher, which includes `./?.lua`,
would still find them first. Rebuild pre-release output trees; there is no
compatibility layer for older providers or loader files.

## Reserved `titan` name

The bare logical module name `titan` is reserved for the Lua support module
that `require "titan"` loads. A library build rejects a source module named
exactly `titan`, including a transitive source dependency, and the Titan
searcher never resolves that name. A *physical* provider named `titan` is
valid; the standard library is the canonical provider with this name, and it
does not contain the support module.

## Compiled compatibility

Every provider carries ABI marker `2`, checked before serialized metadata is
decoded or native entries are used. The current contract covers canonical
Array proxies, function-closure branding, unions, Interfaces, generic metadata,
source-private provider identity, source foreign callbacks, callable naming,
public standard-library signatures, and const-qualified descriptors and
wrappers. Consumer-private closure adjustment wrappers add no provider symbol,
schema, or module-state slot. A mismatched provider is rejected rather than
adapted.

Within that ABI, a separate shared provider may be replaced while preserving
only the declarations each compiled consumer requires. Used callable
signatures, variable contracts, and public nominal shapes are checked at load
time; unrelated exports need not match. Source and archive dependencies already
linked into the same binary retain their fixed implementation. See
[Replacing shared-library dependencies](binary-compatibility.md) for private
record changes, constructors, aliases, and union control-flow requirements.

The release version is independently `TITAN_VERSION` `0.6.0`; its derived
`0.6` library version selects `TITAN_PATH_0_6` and `lib/titan/0.6`. Earlier
Titan installations are neither migrated nor cleaned up.

## Standalone programs

Executable mode is unchanged. If exactly one requested source module declares
the exact `main(args: {string}): integer` entry, Titan links the source closure
into one executable. It does not derive a library provider and emits no DSO.
Unrelated requested roots are consequently legal in one program.

## The standard-library provider

Titan's standard library is the twenty-six-root production example of this
model. One
paired provider:

```text
$ROCKS_TREE/lib/titan/0.6/titan.so
$ROCKS_TREE/lib/titan/0.6/titan.a
```

contains the independent logical modules
`titan.coroutine`, `titan.uv`, `titan.async`, `titan.timer`, `titan.io`,
`titan.fs`, `titan.net`, `titan.ssl`, `titan.url`, `titan.http`, `titan.websocket`, `titan.os`, `titan.path`,
`titan.peg`, `titan.string`, `titan.math`, `titan.lua`, `titan.iteration`,
`titan.gc`, `titan.test`, `titan.reflect`, `titan.sqlite3`, `titan.json`,
`titan.protobuf`, `titan.transfer`, and `titan.thread`. Lua reaches each of
them with `require` through the Titan searcher; a plain `lua` at
`$ROCKS_TREE/bin/lua` finds the provider in its default
`!/../lib/titan/0.6` directory. The separate support module is installed as an
ordinary Lua C module:

```text
$ROCKS_TREE/lib/lua/5.5/titan.so
```

The same compiled provider supplies `titan.test` to applications and native
test executables. The generated runner uses its public `Case.new` and `run`
API; installation does not publish an extra test-support source file.

The DSO is also the installation's one complete dynamic libuv provider; the
archive carries the same private libuv object payload. Both
forms also carry the private, metadata-free LPegLabel objects used through
`titan.peg` by `titan.string` and `titan.url`, plus the llhttp objects and
narrow callback adapter used by `titan.http`. `titan.ssl` calls OpenSSL
directly; system OpenSSL is the default, while bundled OpenSSL mode carries
its OpenSSL objects.
None of those private archives is an installed SDK library. The SDK includes
public libuv, llhttp, and SQLite headers, plus OpenSSL headers in bundled mode. There are
no production child DSOs, aliases, symbolic links, hard links, or Lua loader
files. `require "titan.async"` and `import "async"` still select the same
logical module and state; only their physical provider has been combined.
