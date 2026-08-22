# Language-server compiler I/O strategy

Status: complete. The semantic-metadata branch exposes the incremental analysis
contract consumed by `vscode-titan`, and every analysis-time filesystem wait,
subprocess wait, and cooperative checkpoint now uses one resolver-context
strategy. Ordinary `titanc` and compiler tests retain a plain Lua
implementation; the language server supplies the Lua proxy for a Titan record
implemented with `titan.fs`, `titan.os`, and `titan.async`.

## Decision

`driver.new_resolver_context(options)` owns exactly one `options.io` strategy.
If omitted, the driver installs the canonical synchronous Lua strategy. The
compiler and C parser call methods on that object and do not branch on its
implementation language.

The language-server strategy is a Titan record exposed through its ordinary
Lua proxy. Its methods may suspend the active Titan Task directly. Titan's
tagged nested-coroutine machinery carries that suspension through the active
Lua-to-Titan call chain; there is no request-record interpreter and no Lua
coroutine shim. Its `yield` method calls `async.yield`. The synchronous Lua
strategy's `yield` method is a no-op.

The shared embedded Lua state and compiler registries remain serialized by the
language server's compiler scheduler. Async I/O improves responsiveness and
cancellation; it does not authorize concurrent compiler-state mutation.

## Contract

Add `titan-compiler.io` as the sole synchronous implementation and validator.
The exact strategy surface should stay operation-oriented rather than expose
Lua file handles, so the Titan implementation can use libuv without adding a
seekable standard-library file facade. It must cover the analysis paths with
ordinary Lua values:

- read and atomically write complete files;
- stat and lstat metadata, readability, directory enumeration, realpath, and
  current-directory lookup;
- temporary-name creation, mkdir, unlink, rmdir, and rename used by C probes;
- captured argv execution with exact stdout/stderr and exit/signal state;
- an explicit cooperative `yield` checkpoint.

Methods return the existing compiler success/error shapes rather than leaking
backend-specific exceptions or Titan records into compiler state. The Lua and
Titan implementations must agree on missing paths, broken symlinks,
permissions/readability, byte preservation, directory entries, process status,
and cleanup errors. Strategy validation happens when the resolver context is
created and reports the missing or non-callable method.

The unreleased language-server surface remains at
`LANGUAGE_SERVER_API_VERSION = 3`; this work completes the strategy contract
within that version. API 3 guarantees that every I/O operation reachable from
language-server analysis, external resolution, or C-header restatting is routed
through the supplied strategy.

The same unreleased API also retains each checked generic syntax argument on
its private `_resolved_typearg` edge. Generic lowering preserves that exact
descriptor for source tooling while coder boundary validation skips it, so the
language server can render specialized hover summaries without reconstructing
checker semantics from erased surface syntax.

An adversarial hard-link regression later proved that the existing async
`fs.Stat` record discarded physical identity which LuaFileSystem had supplied
to synchronous compiler callers. The approved minimal standard-library change
adds equality-only `device` and `inode` fields to `fs.Stat`; it adds no new I/O
operation and lets both strategy implementations preserve the same stat
contract without blocking or spawning helper processes.

## Implementation phases

### 1. Prove and establish the boundary

- Add a native `vscode-titan` test in which Lua invokes a method through a
  Titan-record proxy, that method performs an async filesystem operation and
  `async.yield`, and the owning Task resumes with the result.
- Add `titan-compiler.io` with the synchronous Lua strategy and focused unit
  tests for its complete surface.
- Store the validated strategy in every resolver context and thread it through
  public analysis helpers. Preserve omitted-option behavior for existing
  callers.
- Replace the special `after_source_check` callback with
  `context.io:yield(module_name)` after a source module is fully published and
  its dependency frame is popped. The synchronous strategy ignores the module
  name; async clients can use it for bounded progress reporting.

### 2. Route compiler analysis I/O

- Route source discovery, folder enumeration, source reads, path
  canonicalization, dynamic/static provider existence checks, bounded archive
  reads, generated checking-header temporaries, cleanup, external resolution,
  and header restatting through the context strategy.
- Pass the same strategy into `c-parser.cdriver`, `c-parser.cpp`, and
  `titan-compiler.cprobe`. Refactor preprocessing entry points to consume
  complete byte strings where they currently require Lua file handles; do not
  add a second async file abstraction or read a header twice merely to test
  existence.
- Route C compiler discovery/probes through strategy argv capture. Preserve
  `LANG=C`, `LC_ALL=C`, merged-output policy, exact exit/signal normalization,
  cancellation cleanup, persistent-probe cache publication rules, and the
  pre/post input identity checks.
- Let `staticmetadata.scan_archive` obtain its bounded byte input through the
  strategy. Build/publication-only streaming verification may retain the
  synchronous default because it is not reachable from language-server
  analysis, but the boundary must be explicit and tested.

### 3. Eliminate pre-context blocking I/O

- Remove module-load `driver.configure_foreign_c()` and `uname` subprocess
  work. `titanc` explicitly initializes through its synchronous context; the
  language server initializes through its Titan-backed context.
- Make checkout/install-root discovery and default C include discovery lazy so
  any filesystem access needed by the language server occurs only after its
  strategy exists. Environment reads and pure path parsing may remain ordinary
  Lua operations.
- Audit every `io`, `lfs`, `os.execute`, and `io.popen` reference reachable
  from `defaultloader`, `resolve_external_modules`,
  `restat_c_header_dependencies`, resolver finalization/close, and the checker
  C-probe service. Add a fail-fast test strategy whose forbidden fallback
  methods prove that the real language-server paths do not escape the object.

### 4. Implement the Titan strategy and Task ownership

- Add a source-private `CompilerIO` record in `vscode-titan`. Filesystem
  methods use `titan.fs`; captured compiler processes use `titan.os` with
  concurrent output draining and wait, bounded cleanup, and cancellation-safe
  child termination; `yield` uses `titan.async`.
- Pass the record proxy into compiler configuration, analysis, external
  resolution, and header restatting. Remove the Lua-coroutine
  `after_source_check` adapter and its unsafe-boundary comment.
- Keep protocol serving, semantic requests, and project refresh in their
  existing Tasks. Make individual dirty-root/module attempts explicit Tasks
  only where their result ownership is independent; every attempt still holds
  the compiler scheduler permit for the complete Lua-state transaction.
- On cancellation, close the resolver/probe service, terminate owned child
  processes, discard the abandoned compiler registry/import graph, release the
  scheduler permit, and publish no partial generation.

### 5. Verification and documentation

- Compare the synchronous and Titan strategies on file bytes, missing and
  unreadable paths, symlinks, directory ordering inputs, temp publication,
  compiler success/nonzero/signal/missing-executable results, and cleanup.
- Add compiler tests for strategy validation and routing through project
  sources, external flat/folder sources, static providers, FFI headers,
  forced `-include`/`-imacros`, persistent probe hits/misses, restatting, and
  cancellation at a yielded checkpoint.
- Add server tests proving requests can complete from the immutable view while
  compiler file/process I/O is suspended, and that fresh requests join the
  correct generation.
- Update `doc/implementation/driver.md`, the `vscode-titan` bridge docs and
  agent guidance, and the API-version handshake tests.
- Run focused compiler/C-parser/server tests, the complete Titan gate, refresh
  the isolated `.titan` toolchain, then run the complete `vscode-titan`
  verification before either repository is published.

## Non-goals and invariants

- Do not embed compiler Lua modules in the language-server executable.
- Do not add unsaved-buffer semantics or retain external annotated ASTs.
- Do not run two compiler transactions concurrently in the shared Lua state.
- Do not change ordinary `titanc` command behavior, compiler diagnostics,
  header identity semantics, or persistent-cache trust rules.
- Do not add a new Titan standard-library API unless an existing `fs`, `os`,
  or `async` primitive is proven insufficient by a focused test.
- Native dynamic loading and CPU-bound parsing/checking remain synchronous
  work on the compiler Task; this plan makes their surrounding I/O waits async,
  not the Lua state multithreaded.
