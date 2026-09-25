# Native storage allocation audit

The issue #174 migrations were checked with two independent forms of evidence:
allocator measurements of storage replicas and inspection of the actual generated
standard-library factories. The reproduction is
[`spec/support/nominal_allocation_audit.lua`](../../spec/support/nominal_allocation_audit.lua).

Run it from a checkout whose standard provider and installed compiler/SDK have
just been rebuilt together. Use the same current compiler revision even while
the prerelease version and ABI markers remain unchanged. The output directory
must not exist:

```sh
PREFIX=/tmp/titan-174-validation \
  /tmp/titan-174-validation/bin/lua \
  spec/support/nominal_allocation_audit.lua /tmp/titan-storage-audit
```

The script snapshots `titan/uv/uv.c`, `titan/http/http.c`, and `titan/fs.c` before
compiling its disposable module. It uses the installed compiler, the prebuilt
runtime, and libuv's Linux `-D_GNU_SOURCE` header context. It changes no checkout
source, generated module, or installed provider. `--prepare-only` writes the
replicas without compiling; `--audit-only` also checks existing generated C
without building or executing the replicas.

## What the measurements mean

The allocator interceptor counts fresh `LUA_TUSERDATA` requests after module
initialization. Baseline replicas construct the former separate owned C objects
and their nominal wrapper. Migrated replicas use the same native types with
embedded fields or direct fresh const-tail arguments. Their traced collaborator
is a preexisting value, so callback closures, Tasks, Call wrappers unrelated to
the specified storage group, collection setup, temporary scratch, and native
library allocations do not enter the measurement. The Work row deliberately
includes its Call wrapper because that wrapper previously retained the carrier.

These are **measured storage replicas**, not measurements of complete production
operations or a run of the historical compiler. Replica byte sizes are not
reported as complete standard-library owner sizes: replacing collaborators with
one `value` field intentionally changes bookkeeping. The NativeIntArray probe
uses the exact issue declaration and constructor, so its requested byte sizes
are reported separately.

Observed on Linux x86_64 with Lua 5.5.1 and GCC 16.2.1:

| Storage group | Owned baseline | Embedded/fused |
| --- | ---: | ---: |
| HTTP Parser, native parser, settings | 3 | 1 |
| Filesystem request | 2 | 1 |
| Stream write request | 2 | 1 |
| DNS request | 2 | 1 |
| Connect request | 2 | 1 |
| Shutdown request | 2 | 1 |
| One-shot timer | 2 | 1 |
| Repeating timer | 2 | 1 |
| TCP handle | 2 | 1 |
| Process handle | 2 | 1 |
| Signal handle | 2 | 1 |
| Runtime loop | 2 | 1 |
| Realpath request | 2 | 1 |
| Filesystem watcher | 2 | 1 |
| Pipe native variant | 2 | 1 |
| TTY native variant | 2 | 1 |
| Filesystem read request and buffer | 3 | 1 |
| Spawn options and three-element stdio array | 3 | 1 |
| Work Call, carrier, owner, request | 4 | 2 |

The pipe/TTY rows exclude the unchanged enclosing stream wrapper. The process
row excludes its existing `ProcessExitResult`; the realpath row excludes its
existing `ResumeToken`.

| NativeIntArray length | Userdata allocations | Requested bytes | UV slots |
| ---: | ---: | ---: | ---: |
| 0 | 1 | 52 | 0 |
| 16 | 1 | 112 | 0 |
| 1024 | 1 | 4144 | 0 |

These byte counts exclude allocator overhead and shared metadata and depend on
the target's Lua/C layout. Zero length still reserves a distinct aligned tail
address. The generated `NativeIntArray.make` body is also checked for exactly one
`luaS_newudata` and no temporary backing allocation.

## Evidence from the real factories

`canonical-fixed-factories.c.txt` retains the actual HTTP, filesystem, and libuv
factory bodies. Each must allocate the appropriate native payload directly, with
the expected number of userdata sites. Most contain one; process and realpath
contain two because their unchanged result/token records are also constructed.
The separate native C owner allocations are absent.

`canonical-tail-factories.c.txt` retains and checks `new_fs_request`,
`WorkCall:dispatch`, and `os_spawn_config_new`. Each tail must contribute its
checked extent to the final allocation, and the installed field pointer must be
the address of that same userdata plus the computed aligned offset. Work and
spawn have one userdata site each. The filesystem helper has two mutually
exclusive sites: a fused read buffer and a non-read NULL view. Its read path is
checked separately from the ordinary fixed filesystem owner; finding the
synthesized constructor alone would not establish fusion.

`canonical-c.txt` includes complete native member declarations, synthesized
allocation lines, interior-address projections, and native initialization or
submission calls. Reviewing those together confirms that `llhttp_init` receives
the final Parser's native/settings addresses; loop, timer, TCP, signal, watcher,
pipe, and TTY initialization receives the embedded member of its final owner;
and request submission uses the final request member. Spawn options point to the
configuration's own stdio tail, and work request data points to its owner's
carrier. No initialized handle is subsequently copied to a new owner.

The output directory also retains `measurements.md`, `compile.log`, the exact
replica source, `native-array-c.txt`, and all three canonical C snapshots, so
counts and source inspection can be reviewed against the same generated code.
Behavior, cancellation, cleanup, rooting, and callback lifetime remain covered
by the native standard-library and sanitizer suites.
