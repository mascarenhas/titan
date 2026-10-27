# Compiler-owned build coordinator

A single `titanc` invocation owns module-graph discovery, in-process object
certification, parallel frontend and native compilation, output-tree locking,
`--c-source` object compilation, `--test-dir` root discovery, and final-link
certification. The implementation is split across:

* `titan-compiler/build.lua` — output-domain `.titan-build.lock` acquisition,
  closure planning (`build.imports_for`), the topological scheduler
  (`build.new_scheduler`), and the CLI entry point (`build.run`);
* `titan-compiler/build_worker.lua` — the short-lived worker process spawned
  for each module that misses certification;
* `titan-compiler/process.lua` and `titan-compiler/jobs.lua` — the
  cross-platform `luv` worker/job transport, framed `graphcodec` control
  records, and the single job-slot ledger that participates in a parent GNU
  Make jobserver;
* `titan-compiler/nativeinputs.lua` — native flag normalization and certified
  `--c-source` nodes under `<output>/.native/`;
* `titan-compiler/linkcertificate.lua` — per-target final-link certificates
  under `<output>/.titan-links/<key>/`; and
* `titan-compiler/testroots.lua` — recursive `--test-dir` root discovery.

Per-module `.titan.source` record layouts, `incremental.certify_local`, and
`incremental.verdict` are covered in [Object-backed source
modules](incremental-compilation.md). User-facing CLI workflows and Make
patterns are in [Incremental and separate
compilation](../language/incremental-compilation.md) and [Output
directories](../language/output-directory.md).

## End-to-end invocation sequence

When `titanc` runs (`titanc`, excluding `--print-root`), it executes these
phases in order. `--print-ast` shares the planning and output preflight of
step 4 through `build.plan`, then checks and prints its source ASTs in-process
instead of dispatching workers:

1. **Normalize native inputs.** `nativeinputs.normalize` combines platform and
   profile defaults, `TITAN_EXTRA_CPPFLAGS`/`CFLAGS`/`LDFLAGS`, and repeatable
   CLI compile/link switches (`-I`, `-D`, `--cflag`, `-L`, `-l`/`--link`,
   `--ldflag`) into ordered `compile_argv` and `link_argv` lists, which
   `driver.apply_native_inputs` installs before `driver.configure_foreign_c`.
2. **Discover test roots.** When `--test-dir` is given, `testroots.discover`
   enumerates matching source modules inside the configured `--tree` roots and
   merges them after explicit positional roots.
3. **Lock output domains.** `build.lock_outputs` acquires an exclusive OS lock
   on `.titan-build.lock` in every output domain before any object or link
   record is read: the `--output` directory, or without `--output` every
   `--tree` source root plus the working directory, and the `--exe`
   directory when one is given. The first domain also hosts `.native/`,
   `.titan-links/`, and `.titan/`. With `--output`,
   `incremental.load_digest_cache` then loads `<output>/.titan/digests`
   ([Persistent digest cache](incremental-compilation.md#persistent-digest-cache)).
4. **Coordinate the module closure.** `build.run` resolves the transitive
   import closure, runs the [pre-dispatch output
   preflight](#pre-dispatch-output-preflight), certifies hits in-process
   without parsing source, runs one worker process per miss under the shared
   `--jobs` slot ledger, publishes staged objects, restores every module into
   `driver.imported`, and calls `driver.finalize_resolver_context`.
5. **Compile `--c-source` nodes.** `nativeinputs.compile` preprocesses and
   certifies each requested C file under `<output>/.native/`, compiling only
   misses and prepending the resulting `.o` paths before `-X` payloads. A
   compile-only invocation stops here; with `--print-c-objects` it writes one
   absolute object path per `--c-source` argument to stdout after releasing
   its locks. A `-c` invocation with `--c-source` files and no Titan roots or
   `--test-dir` skips the module graph and the Titan foreign-type profile: it
   initializes only the platform, runs the output preflight with an empty
   plan, and still computes the toolchain identity and preprocesses and
   certifies each C node.
6. **Gate the final link.** Unless `-c` is active, `linkcertificate.prepare`
   builds the target's recipe and output inventory,
   `driver.prepare_foreign_headers` restores any missing `.ffi.h`/`.titan.h`
   companions, and `linkcertificate.check` verifies the existing link record,
   output files, and native library inputs. A hit prints `Titan link hit
   <target>` (under `-v`), releases the locks, and returns before runner or
   entrypoint synthesis, archive probing, or native linking.
7. **Synthesize, link, publish, and commit.** On a link miss,
   `linkcertificate.invalidate` removes the old link record before any final
   artifact is modified. `titanc` synthesizes any test runner and entrypoint
   under `<ticket.synthetic_directory>`, runs generated-object and archive
   validation, links and publishes the executable or provider bundle, and
   writes `<ticket.record>` last via `linkcertificate.commit`.

Every exit path saves a changed digest cache before releasing the locks; a
save failure never replaces the invocation's own diagnostics.

## Output-tree coordination

Concurrent `titanc` invocations sharing an output tree or an external `--exe`
destination—such as an application build and a `--test` build running in
parallel under Make—are serialized across the entire certification, compilation,
and publication window by `build.lock_outputs(strategy, directories, options)`
(`titan-compiler/build.lua`) and `titan._output_lock_open(path)`
(`titan-runtime/ltitanlib.c`).

### Lock file and OS primitives

In each target directory (created with missing parents through `strategy`), the
coordinator opens `<directory>/.titan-build.lock`. The lock file is permanent
and is never unlinked on release: unlinking a lock file would allow two
processes to hold exclusive locks on different inodes for the same path.

`_output_lock_open` opens the file without following a symbolic link or reparse
point at the leaf and verifies that the handle refers to a regular disk file:

* **POSIX (`Linux` and `macOS`).** Opens `<path>` with
  `O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK` (`0666`), rejecting
  `ELOOP` with `build lock '<path>' is a symbolic link`. `fstat` must report
  `S_ISREG(info.st_mode)`. The lock's canonical identity string is
  `"posix:<st_dev>:<st_ino>"`. `lock:try()` calls `flock(fd, LOCK_EX | LOCK_NB)`.
  After `flock` succeeds, `lock:linked(path)` checks that `fstat(fd)` and
  `lstat(path)` still report the same `st_dev` and `st_ino`; if another process
  removed and recreated the directory tree while this invocation waited, the
  coordinator closes the orphaned handle and reopens `<path>`.
* **Windows.** Converts the UTF-8 path to UTF-16 and calls `CreateFileW` with
  `GENERIC_READ | GENERIC_WRITE`, share mode
  `FILE_SHARE_READ | FILE_SHARE_WRITE` (omitting `FILE_SHARE_DELETE` so the
  lock file cannot be deleted or renamed while any handle is open),
  `OPEN_ALWAYS`, and `FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT`.
  `GetFileType` must be `FILE_TYPE_DISK` and `GetFileInformationByHandle` must
  report neither `FILE_ATTRIBUTE_REPARSE_POINT` nor `FILE_ATTRIBUTE_DIRECTORY`.
  The canonical identity string is
  `"win:<dwVolumeSerialNumber>:<nFileIndexHigh>:<nFileIndexLow>"`. `lock:try()`
  calls `LockFileEx(handle, LOCKFILE_EXCLUSIVE_LOCK | LOCKFILE_FAIL_IMMEDIATELY,
  0, 1, 0, &range)` over byte 0.

Closing the lock (`lock:close()`, `LockSet:release()`, Lua GC finalization, or
OS process termination) releases the kernel lock.

### Deduplication, acquisition order, and waiting

`build.lock_outputs` opens every requested directory's `.titan-build.lock`
first, deduplicates entries with equal `lock:identity()` (closing duplicate
handles when lexical, symlink, case, or mount aliases resolve to the same
physical file), and sorts the remaining entries bytewise by `identity` before
acquiring any lock. Two processes locking overlapping domain sets in opposite
CLI orders therefore acquire them in the same canonical order and cannot
deadlock.

When `entry.lock:try()` reports that another process holds the lock, the
coordinator prints `titanc: waiting for build lock '<path>'` once to `stderr`
when `-v` is enabled and sleeps in 50 ms increments (`LOCK_POLL_MILLISECONDS`)
through `luv.sleep` without holding any GNU Make jobserver token. Because the
locks are acquired before `build.run` or `linkcertificate.prepare`, a waiting
second invocation certifies against the disk state left by the first invocation
after it finishes. Any open or lock failure aborts the invocation; there is no
PID-staleness heuristic or unlocked fallback. Output-tree locking covers local
POSIX filesystems and Windows NTFS; network filesystems (such as NFS or SMB
shares without coherent `flock`/`LockFileEx` semantics) are not supported
coordination domains.

## Closure planning and import scanning

`build.run(context, request)` (`titan-compiler/build.lua`) discovers
the module graph through `driver.defaultloader({}, loader_options)` with
`plan_mode = true` and `imports_for = build.imports_for`:

1. **Tagged source and provider selection.** For each module reached from
   `request.roots`, the loader applies the ordinary selection rules
   ([Source vs compiled providers](driver.md#source-vs-compiled-providers-the-selection-logic)):
   command-line roots and explicit `.titan` imports are source-required,
   `--test` and `--source-first` prefer source with compiled fallback on a
   clean miss, and ordinary imports run the complete `.so`/`.a` passes (swapped
   by `--static`) before falling back to source. Selecting a later source
   module rebinds any overlapping static archive (`rebind_overlapping_static_providers`).
2. **Stage-1 local certification.** When `request.incremental` is true and the
   source descriptor is not in-memory, `plan_source` (`driver.lua`)
   calls `driver.incremental_configuration(context)` and
   `incremental.certify_local(context, modname, source)`.
3. **Import list recovery or lexical scanning (`build.imports_for`,
   `build.lua`).**
   * If `certify_local` returned `certified.imports`—which happens whenever the
     existing `.o` record decodes with the current schema and its own-source
     membership and SHA-256 content hashes match, even if `configuration`,
     `codegen-options`, `parts`, or `c-input` missed—`build.imports_for`
     returns that saved import list directly without reading or scanning the
     `.titan` files again.
   * Otherwise, `build.imports_for` reads each constituent in canonical order
     (`source.main` first, then bytewise-sorted contributors) and calls
     `parser.scan_imports(contents)` (`titan-compiler/parser.lua`).
   * `parser.scan_imports` uses an LPeg grammar built from the compiler's own
     lexer tokens (`lexer.SPACE`, `lexer.COMMENT`, `lexer.LOCAL`, `lexer.NAME`,
     `lexer.ASSIGN`, `lexer.IMPORT`, `lexer.LPAREN`, `lexer.RPAREN`,
     `lexer.STRINGLIT`, and `lexer.any_token` in
     `titan-compiler/lexer.lua`) to match `local <name> = import
     "<mod>"` and `local <name> = import ( "<mod>" )` while stepping over
     comments, long strings, and other tokens whole. Each matched string is
     normalized with `parser.normalize_import(modname)`, which strips a
     terminal `.titan` into `source_required = true` and expands short
     standard-library names.
   * If `scan_imports` fails on an unrecognized token, `build.imports_for`
     falls back to `parser.parse(file, contents)` and extracts
     `Ast.TopLevelImport` nodes; if `parser.parse` also fails (a syntax error),
     it returns `{}` so planning continues and the module's worker later reports
     the normal located syntax diagnostic.
   * `import_list` deduplicates imports per module in first-seen order,
     combining `source_required = previous.source_required or
     import.source_required`.
4. **Placeholder recording.** `plan_source` installs a lightweight placeholder
   `{ kind = "source", _planned = true, filename, source_files, native_output,
   program_output, deps }` in `driver.imported[modname]` and records any failed
   child import in `node.failed` and `planning.unavailable` without aborting
   discovery of sibling branches. Only a missing or blocked root fails before
   scheduling.
5. **Closing the plan (`driver.resolution_plan(context)`,
   `driver.lua`).** After all roots are traversed,
   `driver.resolution_plan` closes the planning loader and constructs:
   * `plan.modules[name]`: `{ kind = "source", source, certified, imports,
     failed, cyclic? }`, `{ kind = "dynamic", file, relative, provider_file }`,
     `{ kind = "static", archive, relative }`, or `{ kind = "unavailable",
     error }`;
   * `plan.order`: all acyclic source modules in topological order
     (dependencies before dependents, ties broken bytewise by module name),
     followed by any import-cycle members (`cyclic = true`) in bytewise order;
     and
   * the plan query methods `plan.linked(name)`, `plan.provider_file(name)`,
     `plan.digest(name, view)`, `plan.update(name, certified)`, and
     `plan.accepted(name)`.

Only modules reachable in the import closure of `request.roots` are visited; an
unimported malformed `.titan` file elsewhere in the source tree is never read.

### Pre-dispatch output preflight

`build.plan(context, request)` loads the ordered roots with the planning
loader and closes `driver.resolution_plan`. Immediately afterwards, and before
any scheduler decision, invalidation, or worker launch, `build.run` calls the
coordinator-only `request.preflight(plan)` closure, which `titanc` binds to
`driver.preflight_build_outputs(context, plan, options)`. The `--print-ast`
path calls the same `build.plan` and preflight before any native output, then
clears the planning placeholders from `driver.imported` so its ordinary
loader checks the real sources. A failure aborts the
invocation before any planned module output or final target is invalidated or
written. Earlier planning may already have refreshed compiler bookkeeping such
as `.titan/preamble.c`, and the exit path still saves the digest cache. The
pass itself never runs the checker, code generator, or C preprocessor:

* **Reserved outputs.** Every planned source module, cached or fresh, reserves
  `<stem>.c`/`.o` and every potential split part
  `<stem>.part<k>.c`/`.part<k>.o` with `1 <= k < effective c_parts`, each
  unit's `.gcno` and `.gcda`, any parts recorded by a validated prior primary
  object (so a smaller split policy can still retire them), and
  `<stem>.priv.h`, `<stem>.titan.h`, and `<stem>.ffi.h`. Potential part names
  are reserved even when the module would generate fewer parts. An existing
  generated header must carry its ownership marker, and an existing file at a
  reserved `.c` path must begin with the generated-C marker (or the exact
  legacy fixed-helper or split-header prefix); otherwise the build fails with
  `native provider output '<path>' for <owner> aliases input '<path>' (not
  compiler-generated C)` instead of overwriting authored source.
* **Final outputs.** The pass reserves the actual program path and Darwin
  `.dSYM`, the Windows launcher and provider DLL, or the library provider,
  archive, `.dSYM`, and generated Lua shims, including shims of modules
  carried by already-selected static archives.
* **Protected inputs.** `--c-source` files and `-X` payloads, every source
  constituent, the non-`search` C headers recorded by cached modules, selected
  binary providers and archives, every held `.titan-build.lock` file, and the
  metadata roots `.titan/`, `.titan-links/`, and `.native/` of the first lock
  domain are inputs that no output may alias. Final outputs that would replace
  a lock file or a metadata root are therefore rejected before any
  invalidation.
* **Graph-dependent CLI checks.** For roots without a certified record, the
  pass parses declarations only and follows transparent local and imported
  aliases to find an exact `main(args: {string}): integer`. It then rejects
  multiple `main` roots, `--exe` or `--no-uv-bootstrap` without a standalone
  or test executable, `--coverage` on a library-only link, library roots with
  no common module prefix, and logical modules whose C symbol prefixes
  collide. The ordinary checker remains the authority for declaration
  validity.

`driver.validate_provider_output_paths` checks the whole set through
`perf.new_output_path_index`. The index observes each pathname once (`lstat`,
then `stat` for links) and keys it by normalized spelling, physical path
(existing ancestors resolved through `realpath` on POSIX), lowercased physical
path, and, on POSIX, device and inode. Exact maps and component-prefix trees
detect aliases, hierarchy conflicts (an output that is an ancestor of another
output or input), and wrong existing kinds without further filesystem
queries. On Windows the index reads file status through the compiler I/O
strategy's `lstat`/`stat`, the same native observations the rest of the
compiler uses, rather than LuaFileSystem.

Fresh modules discover their C headers only in their worker. After checking
and before writing generated module artifacts (C, headers, and objects),
`driver.compile_planned_module` passes each non-`search` entry of the module's
`c_header_dependencies` to
`driver.validate_reserved_output_inputs(plan.reservations, inputs)`, so an
authored header at a reserved path fails that module before any generated
artifact overwrites it. Checker and C-probe scratch files may already exist by
then.

## Metadata-only hits and early cutoff

`build.new_scheduler(nodes, hooks, options)` (`build.lua`) builds a
dependency DAG over the planned source `nodes`. Cyclic nodes (`module.cyclic`)
are given no DAG prerequisites (`node.remaining == 0`) so they are immediately
scheduled as misses and their workers report the standard `"circular reference
to module"` checker error.

Whenever a node has `node.remaining == 0`, it enters `scheduler.decisions`,
which is kept sorted by `node.index` (`plan.order`). `Scheduler:drain_decisions()`
invokes `decide(node)` (`build.lua`) in-process:

1. If `module.error` is set, the node fails immediately.
2. If `not request.incremental` or `module.cyclic`, the node transitions to
   `state = "ready"` (`insert_ready`, sorted bytewise by `node.name`).
3. If stage 1 `module.certified` (`certify_local`) missed, `decide` buffers
   `Titan object miss <name>: <reason>[ <detail>]` in `node.stderr` (when `-v`
   is active) and marks the node `"ready"` for a worker.
4. If `module.certified` hit, `decide` calls
   `incremental.verdict(certified.record, plan)`. Because `decide` runs only
   after every dependency in `node.deps` has reached `state == "done"` and
   called `plan.update(dep, certified)`, `plan.digest(dep, view)` already holds
   each dependency's current self digest—whether that dependency was itself a
   warm hit or was just recompiled and published by a worker.
5. **Early cutoff.** When `verdict.status == "hit"`, `decide` calls
   `driver.restore_source_object(context, node.name, module.source, certified)`,
   calls `plan.update(node.name, certified)`, and marks the node `"done"`,
   decrementing `remaining` on its dependents. Thus, when a producer module is
   recompiled after a body-only edit and its new record produces the same
   `interface.public` (and `interface.source` for `.titan` importers), its
   consumers hit in-process and never spawn a worker or run `cc`.
6. When `verdict.status == "miss"` (or if `restore_source_object` returns `nil,
   code, detail`), `decide` buffers the miss line in `node.stderr` and queues
   the node in `scheduler.ready`.

On a warm build where every source module hits in `decide`, `scheduler.ready`
remains empty after `drain_decisions()`. `Scheduler:run()` (`build.lua`)
then skips opening the jobserver ledger, skips installing signal or `SIGPIPE`
guards, spawns zero workers, flushes buffered `-v` hit lines in `plan.order`,
and returns `true`.

## Build-worker transport

When `scheduler.ready` is nonempty, the coordinator spawns one short-lived Lua
worker process per missed module (`titan-compiler/build_worker.lua`, launched by
`process.start_worker` in `titan-compiler/process.lua`).

### Worker launch and descriptor layout

`worker_argv` (`build.lua`) resolves the currently running Lua
interpreter via `luv.exepath()` and constructs:

```lua
{
    interpreter, "-E", "-e",
    string.format(
        "package.path = %q; package.cpath = %q; require(%q).main()",
        package.path, package.cpath, "titan-compiler.build_worker"
    ),
}
```

The worker is spawned directly by `uv.spawn` (never through a shell or a `PATH`
lookup for `titanc`) in the coordinator's working directory and environment. It
therefore loads the exact compiler Lua files and native `titan` support library
that the coordinator loaded. The child's descriptors are:

* `fd 0` (`stdin`): an empty pipe whose write end the coordinator closes
  immediately after `uv.spawn`, ensuring `fd 3` and `fds 4..` occupy fixed
  descriptor numbers;
* `fd 1` (`stdout`) and `fd 2` (`stderr`): pipes read to EOF by the coordinator
  into `worker.stdout` and `worker.stderr` for deterministic replay;
* `fd 3`: a private duplex pipe (`uv.new_pipe(false)`) carrying length-prefixed
  control records; and
* `fds 4, 5, ...` (POSIX only): the open `.titan-build.lock` descriptors from
  `locks:descriptors()`.

`process.start(argv, options)` launches a command that shares the caller's
standard streams and returns its `Process` immediately (or `nil, error`);
`:wait()`/`:close()` reap it with `os.execute`-shaped results. Synchronous
`process.run` is `start` followed by `wait`, and `process.capture` collects
output through a pipe. All three accept the same `options.inherit` list and
place those POSIX lock descriptors at `fd 3` and up, so a native tool started
outside the dispatched job batches keeps the output-tree lock alive while it
runs. Workers and
dispatched native jobs keep their own layouts, and every launch passes the
same Windows process-tree guard.

While the scheduler loop runs on POSIX, `titan._sigpipe_ignore()`
(`ltitanlib.c`) sets `SIGPIPE` to `SIG_IGN` and restores the exact prior
`struct sigaction` afterwards, so sending a control record to a worker that
crashed mid-flight fails cleanly with `EPIPE` instead of terminating the
coordinator.

### Control protocol (`titan-build-worker-v1`)

Control messages on `fd 3` (`process.lua`) consist of a 4-byte
big-endian payload length (`string.pack(">s4", payload)`, bounded at
`RECORD_LIMIT = 256 * 1024 * 1024 + 64` bytes) followed by a
`titan-compiler/graphcodec` binary payload verified with SHA-256. Payloads may
contain only strings, finite numbers, booleans, and plain tables; functions and
userdata are rejected.

The message exchange for one worker is:

1. **Coordinator -> worker (`compile`).** Sent immediately after spawn, stamped
   with `version.BUILD_WORKER_PROTOCOL` (`"titan-build-worker-v1"`):

   ```lua
   {
       kind = "compile",
       protocol = "titan-build-worker-v1",
       request = {
           module = modname,
           configuration = driver.worker_configuration(context),
           options = {
               plan = driver.plan_descriptor(plan, modname),
               c_parts = request.c_parts,
               test = request.test,
               coverage = request.coverage,
               pretty_print = request.pretty_print,
               verbose = request.verbose,
               jobs = ledger.limit,
           },
       },
   }
   ```
2. **Worker <-> coordinator (`native` / `native-result`, zero or more rounds).**
   `build_worker.main()` installs `jobs.use_remote(session)` (`jobs.lua`).
   Whenever the worker runs a multi-job C-probe batch (`io:run_batch`) or a
   multi-part generated-C compile (`driver.run_prepared_compiles` with
   `parallelism > 1` and `#jobs > 1`), `remote_drive` (`jobs.lua`)
   sends one batch request:

   ```lua
   {
       kind = "native",
       id = self.batches,
       jobs = {
           { argv = { ... }, stdout = "<log>", stderr = "<log>" },
           ...
       },
   }
   ```

   At most one `native` batch may be outstanding per worker, and only while the
   worker holds its frontend slot lease. Once the coordinator has reaped all
   launched children for that batch and restored the worker's frontend lease,
   it replies with:

   ```lua
   {
       kind = "native-result",
       id = batch.id,
       results = { [index] = { ok = boolean?, term = "exit"|"signal", code = integer } },
       failure = string?,
       cancelled = integer?,
   }
   ```

   Jobs that were never started (because the build stopped or was cancelled)
   are omitted from `results`, and `remote_drive` records a `"not started: ..."`
   finish error on those entries. Single-command `io:run` calls and single-part
   module compiles execute directly inside the worker under its active frontend
   slot lease.
3. **Worker -> coordinator (`result`).** Before exiting with status 0, the
   worker sends exactly one terminal record and closes `fd 3`:

   ```lua
   -- Success:
   {
       kind = "result",
       ok = true,
       result = {
           modname = modname,
           object = "<stem>.o",
           objects = { "<stem>.o", "<stem>.part1.o", ... },
           staged = {
               { from = "<temp0>", to = "<stem>.o", role = "primary" },
               { from = "<temp1>", to = "<stem>.part1.o", role = "part" },
               ...
           },
           diagnostics = {},
       },
   }
   -- Failure:
   {
       kind = "result",
       ok = false,
       diagnostics = { "<error message>", ... },
   }
   ```

Any malformed frame, unknown record kind, unexpected batch or duplicate result,
or non-zero worker exit after `ok = true` is treated as a protocol failure: the
coordinator drops any queued native jobs for that worker, sends `SIGTERM` if
the worker is still alive, and fails the module.

### Planned worker resolution and orphan lifetime

Inside the worker (`build_worker.lua`),
`driver.new_worker_context(request.configuration, worker_io(session))`
(`driver.lua`) restores the coordinator's driver paths, flags,
resolver settings, and `codegen_policy`, then calls
`incremental.compiler_component(context, options)` to hash the loaded compiler
Lua files and frontend script. If the resulting digest differs from
`configuration.configuration.compiler`, the worker fails immediately with
`"compiler installation changed during build"`. The preamble, toolchain, and
compile-options digests are inherited from the coordinator without re-probing.

`driver.compile_planned_module(context, modname, request.options)`
(`driver.lua`) creates a loader with `worker_plan = options.plan`
(`driver.plan_descriptor(plan, modname)`). Under `worker_plan`, the loader
never searches `TITAN_BIN_PATH` or `TITAN_SOURCE_PATH`:

* requesting `modname` itself parses and checks the planned source descriptor;
* requesting any other planned `source` module restores its parent-certified
  `item.object` record via `restore_planned_source` (`driver.lua`)
  without re-running `certify_local` or `verdict`;
* requesting a planned `dynamic` or `static` module loads the exact planned
  `item.file` or `item.archive` via `load_planned_binary`
  (`driver.lua`); and
* requesting any module not in `plan.modules`, or observing a `native_static_names`
  linked set after `finalize_resolver_context` that disagrees with
  `planned.linked`, fails with `"build plan divergence: ..."`.

Worker lifetime is bounded even if the coordinator terminates abnormally:

* **Cooperative abandonment check.** `worker_io(session)` wraps `Sync:yield`
  (`build_worker.lua`) and checks `session:abandoned()` (non-blocking
  `uv.run("nowait")` testing whether `fd 3` reached EOF or error). Both
  `yield` and `Session:run_batch` exit immediately with status 3 (`titanc build
  worker: the build coordinator exited`) if the coordinator closed `fd 3`.
* **POSIX lock inheritance.** Workers inherit the open `.titan-build.lock`
  file descriptors (`fds 4..`), and every native writer the coordinator starts
  receives them too: synchronous `process.run`/`process.capture` commands,
  the shell wrappers of local FIFO-notified native batches, and the
  coordinator's bound `Sync:run` and `run_batch` commands (such as `--c-source`
  preprocessing and foreign-C checks) are launched with the held lock
  descriptors. `titanc` binds the acquired lock set to its coordinator `Sync`
  strategy before digest loading and preflight and clears the binding when the
  locks are released; a bound `Sync:run` (and a serial `run_batch`) runs the
  same locale-prefixed, quoted command through `/bin/sh -c` and
  `process.capture` with the same status and stderr contract, a parallel
  `run_batch` launches its jobs through `jobs.launch` and `process.start_job`
  with the same descriptors, and neither falls back to an unleased `io.popen`.
  An abrupt
  `SIGKILL`
  of the coordinator therefore leaves the kernel `flock` held until every
  surviving worker, native job, and child compiler has exited, and a
  subsequent `titanc` invocation waiting in `build.lock_outputs` cannot enter
  the output tree while an orphan is still writing. Each FIFO wrapper keeps
  the completion FIFO open read-write for its own lifetime, so writing its
  completion line never blocks on a vanished reader while it holds those
  leases.
* **Windows process-tree job.** Before the first spawn through
  `process.lua`, `contain_native_processes` calls the runtime's
  `titan._native_process_tree_guard()`, which creates a Job Object with
  `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` and no breakaway permission and assigns
  the current coordinator or worker process to it. Windows 8 and later nest
  jobs, and every child inherits this strict ancestor job at `CreateProcess`
  time, before it runs, even when libuv also places it in its own job that
  permits silent breakaway; a grandchild started by a compiler wrapper
  therefore cannot escape. The job handle is noninheritable and deliberately
  stays open until operating-system process teardown: the compiler is itself
  a member, so closing the handle from a Lua finalizer would kill the current
  process. Teardown closes it after Lua cleanup, preserving the exit status
  while terminating every remaining descendant, including workers' nested
  jobs. A missing guard function or a failed job creation, configuration, or
  assignment launches no child and is reported as a spawn error. The job
  bounds descendant lifetime only. After a forced coordinator termination on
  Windows, Titan does not guarantee that every descendant has exited before
  the operating system releases the coordinator's `.titan-build.lock`, so a
  waiting invocation is not promised the POSIX lock-inheritance ordering
  above.

## Slot ledger and jobserver rules

When one or more modules miss, `Scheduler:run()` opens a single slot ledger
`jobs.open_slots(self.options.jobs or 1, { guard = true })`
(`titan-compiler/jobs.lua`) shared by all worker frontends and all
multi-job native batches.

### Concurrency invariant, lease handoff, and dispatch priority

At every instant during `Scheduler:run()`:

```text
live workers holding a frontend lease + running coordinator native jobs <= ledger.limit
```

With a shared POSIX GNU Make jobserver (`ledger.shared == true`), the first
active slot uses the implicit slot Make granted to the `titanc` recipe, and
every additional active slot (`active - 1` slots) holds one exact token byte
read from the parent jobserver (`Slots:acquire_nowait` and `Slots:release` in
`jobs.lua`). A slot is released only after its process has been reaped
(or a spawn failed before starting).

Frontend and native slots hand off without deadlocking or exceeding the cap:

1. Starting a worker requires `ledger:acquire_nowait()` to succeed and grants
   the worker `worker.lease = true`.
2. When that worker sends a `{ kind = "native", id, jobs }` batch of `count >=
   1` commands (`Scheduler:worker_record`, `build.lua`), the worker
   yields its frontend lease (`worker.lease = false`). Job 1 of the batch
   immediately inherits that slot via `Scheduler:start_native`, while jobs
   `2..count` are appended to `scheduler.native_queue` in the worker's own
   `cost_bytes`-descending launch order.
3. As each native job completes (`Scheduler:native_done`, `build.lua`),
   if other jobs of the same batch are still running or queued, the completed
   job releases its slot back to the ledger (`Scheduler:release_slot()`). When
   the last job of the batch finishes (`batch.running == 0 and batch.queued ==
   0`) and the worker is still alive, that last job's slot becomes
   `worker.lease = true` again and the coordinator sends the `native-result`
   reply.

`Scheduler:dispatch()` (`build.lua`) assigns available slots in strict
priority order:

1. `resume_queue` — workers whose queued native jobs were dropped when the
   build stopped while zero jobs of their batch were running, and which need a
   slot to receive `reply_stopped` and clean up;
2. `native_queue` — queued native compile or C-probe jobs belonging to modules
   that have already started; and
3. `ready` — unstarted modules in bytewise name order (`util.bytewise_less`).

When work remains in one of those queues and `ledger:acquire_nowait()` returns
`false` (waiting for a parent Make jobserver token), `Scheduler:update_token_poll`
polls `ledger:token_descriptor()` (the private nonblocking read fd of the
jobserver FIFO or Linux reopened pipe, exposed by `client:descriptor()` in
`ltitanlib.c`) with `uv.new_poll` until a token byte becomes readable.
Darwin's kqueue backend rejects named FIFO descriptors in `uv_poll_init`; when
`uv.new_poll` fails, the scheduler instead arms a 5 ms timer so each loop turn
retries the nonblocking `acquire_nowait()`.
All `luv` poll, pipe, and process-exit callbacks enqueue events via
`Scheduler:defer` and never run publication or certification inline.

### GNU Make jobserver modes and old-pipe local cap

`jobs.make_policy(makeflags)` (`jobs.lua`) parses option words before
`--` in `MAKEFLAGS` and selects the last `--jobserver-auth=fifo:PATH`,
`--jobserver-auth=R,W`, or `--jobserver-fds=R,W` entry:

| Parent `MAKEFLAGS` state | Platform | Effective behavior |
| --- | --- | --- |
| `--jobserver-auth=fifo:PATH` (GNU Make >= 4.4) | Linux, macOS | Opens `PATH` privately read-only and write-only (`O_NONBLOCK \| O_CLOEXEC`); shares the parent pool up to `local_cap`. |
| `--jobserver-auth=R,W` or `--jobserver-fds=R,W` (pipe) | Linux | Reopens `/proc/self/fd/R` and `/proc/self/fd/W` privately (`O_NONBLOCK \| O_CLOEXEC`) after `fstat` verifies one pipe; shares the parent pool up to `local_cap`. |
| Valid inherited pipe `R,W` | macOS and other non-Linux POSIX | `_jobserver_open("pipe", R, W)` checks that both descriptors are open FIFOs with readable and writable access modes (Darwin reports distinct inodes for a pipe's two ends, so the descriptors are not required to share one) and returns `nil, reason, "unsupported"`. `jobs.unshareable_pipe_limit` warns once and uses `titanc`'s own `local_cap` (`--jobs` or `TITAN_JOBS`, default 4) outside the parent pool without mutating the parent's shared pipe flags. Sharing the parent pool on macOS requires GNU Make >= 4.4's FIFO jobserver. |
| Unmarked recipe (`-2,-2`), closed/mismatched fds, or unopenable FIFO | Linux, macOS | `warn_unusable` prints one warning per process and sets `limit = 1`. |
| Explicit `-j1` with no jobserver auth | Linux, macOS | Sets `limit = 1`. |
| No `MAKEFLAGS` or no `-j` / unlimited `-j` | Linux, macOS | Uses `local_cap`. |
| Any `MAKEFLAGS` | Windows | Ignores `MAKEFLAGS` (MSYS2 descriptors are not native UCRT descriptors) and uses `local_cap`. |

## Diagnostics, cancellation, and publication

### Deterministic diagnostics and failure handling

Each scheduled node owns `node.stdout`, `node.stderr`, and `node.messages`
arrays (`build.lua`). Certification `-v` lines, captured worker
stdout/stderr, and failure diagnostics are buffered on the node rather than
written as workers finish. `Scheduler:emit()` advances `self.cursor` from `1`
to `#self.nodes` in `plan.order`, flushing a node only after it reaches a
settled state (`done`, `failed`, or `skipped`). `Scheduler:flush` writes both
the captured worker stdout and stderr to the coordinator's stderr, keeping
`titanc` stdout free for requested results such as `--print-c-objects`.
Output and diagnostics are therefore deterministic and independent of worker
completion order.

When a module fails certification, worker compilation, or publication
(`Scheduler:fail`, `build.lua`), the scheduler marks all of its
transitive `waiting` dependents as `skipped` without recording redundant
cascade messages on those dependents. Independent branches of the DAG continue
to run so a single invocation reports all root-cause errors in `plan.order`. A
failed build never proceeds to `--c-source` compilation or final linking.

### Signal cancellation and fatal stops

During `Scheduler:run()`:

* on POSIX, `Scheduler:watch_signals()` polls `ledger:signal_descriptor()`
  (`titan._signal_wake_descriptor()` in `ltitanlib.c`), which becomes
  readable when the `TitanSignalGuard` handler catches `SIGINT`, `SIGTERM`, or
  `SIGHUP`;
* on Windows, `Scheduler:watch_signals()` starts `luv` signal handles for
  `sigint` (2), `sighup` (1), and `sigbreak` (21).

When a signal arrives (`Scheduler:cancel(signo)`) or an internal/jobserver
invariant fails (`Scheduler:fatal(message)`), `Scheduler:stop()`
(`build.lua`) stops starting new modules and empties
`scheduler.native_queue`. Live workers and already-running native compiler
processes are **not** killed: they drain to completion so each worker's
`driver.run_prepared_compiles` removes its own temporary files cleanly. Any
outstanding batch receives `reply_stopped` (`cancelled = signo` or `failure =
"the module build stopped after an earlier failure"`), and any worker that had
already finished and reported `ok = true` after `stop()` has its staged object
temporaries removed by `hooks.discard` (`build.lua`). Once
all live workers and native jobs settle, `ledger:close()` returns every
borrowed jobserver token and restores signal dispositions, `titanc` closes the
resolver context (releasing `.titan-build.lock`), and `jobs.propagate(signal)`
re-raises the signal.

### Staged module publication order

Workers never write committed `<stem>.o` or `<stem>.part<k>.o` files; only the
coordinator publishes module objects:

1. **Pre-worker invalidation (`driver.invalidate_source_object`,
   `driver.lua`).** Immediately before spawning a worker for a missed
   module, the coordinator reads any existing `<stem>.o`'s validated `parts`
   list, unlinks `<stem>.o` **first** (retiring the commit marker), and then
   unlinks every recorded `<stem>.part<k>.{o,c,gcno,gcda}` (`k >= 1`).
2. **Worker staging (`driver.compile_planned_module`,
   `driver.lua`).** Inside the worker, `prepare_compile` runs with
   `options.staged = true`: generated headers (`.ffi.h`, `.titan.h`) are
   written via sibling staging and rename, and `<stem>.c`, `<stem>.part<k>.c`,
   and `<stem>.priv.h` are written at their final paths under the locked output
   tree so `#line` directives and `.gcno` notes carry their final paths without
   remapping. Each part's object is compiled to a unique sibling temporary
   (`job.temporary_object`) returned in `result.staged`.
3. **Coordinator revalidation and commit (`driver.publish_staged_module`,
   `driver.lua`).** When the worker reports `ok = true`, the
   coordinator reads the staged primary object, decodes its `.titan.source`
   record, resolves a fresh source descriptor (`current_source_descriptor`),
   and runs `incremental.revalidate_record(context, modname, source, record)`.
   If validation fails, all `staged[i].from` temporaries are unlinked and the
   module fails. Otherwise, the coordinator unlinks any existing `primary.to`,
   renames sidecar part temporaries `parts[#parts .. 1]` into place from the
   highest part index down, and renames `primary.from` to `<stem>.o` **last**.
   If any rename fails, `<stem>.o` and all remaining temporaries are unlinked,
   leaving no primary commit marker.

## Native inputs and `--c-source` nodes

### Normalization order

`nativeinputs.normalize(options)` (`titan-compiler/nativeinputs.lua`) and
`driver.apply_native_inputs(normalized)` (`driver.lua`) establish one
deterministic flag order across C-header parsing, C probes, preamble
certification, generated module C, `--c-source` nodes, and final links:

1. **Toolchain and profile defaults (`driver.CC`, `driver.CFLAGS`).** Selected
   by `CC` and `TITAN_BUILD_PROFILE` (`production` or `validation`).
2. **Environment extras (`TITAN_EXTRA_CPPFLAGS`, `TITAN_EXTRA_CFLAGS`,
   `TITAN_EXTRA_LDFLAGS`).** Tokenized once with `cdriver.split_shell_words`.
   `TITAN_EXTRA_CPPFLAGS` and `TITAN_EXTRA_CFLAGS` append to `compile_argv` in
   that order; `TITAN_EXTRA_LDFLAGS` appends to `link_argv`.
3. **Repeatable CLI switches in exact command-line order.** `titanc` records
   `-I`/`--include-dir`, `-D`/`--define`, `--cflag`, `-L`/`--library-dir`,
   `-l`/`--link`, and `--ldflag` in a single ordered `native_cli` list as they
   appear on the command line:
   * `-I <dir>` -> `"-I" .. dir` in `compile_argv`;
   * `-D <def>` -> `"-D" .. def` in `compile_argv`;
   * `--cflag <arg>` -> `arg` in `compile_argv`;
   * `-L <dir>` -> `"-L" .. dir` in `link_argv`;
   * `--ldflag <arg>` -> `arg` in `link_argv`;
   * `-l`/`--link <libs>` -> splits comma-separated names (rejecting empty
     components) and appends `"-l" .. name` to `link_argv` for each entry,
     preserving repeats and exact interleaving with `-L` and `--ldflag`.
4. **Trailing SDK include roots (`driver.foreign_include_dirs()`).** Appended
   after `driver.NATIVE_COMPILE_FLAGS` in `driver.generated_compile_prefix()`
   and `driver.toolchain_descriptor(context)`, so user environment and CLI `-I`
   directories are searched before `<root>/include` and
   `<root>/src/lua-5.5.1`.

When `titanc --coverage` is active, `--coverage` and `-fno-lto` are appended to
`driver.NATIVE_LINK_FLAGS` (`titanc`).

### `--c-source` compilation and records

`nativeinputs.compile(context, request)` (`titan-compiler/nativeinputs.lua`)
compiles authored or pre-generated C files using the invocation's
`driver.generated_compile_prefix()` (without Titan-only test-owner or module
coverage flags) and shared `toolchain_identity`:

1. **Deduplication and storage stem.** Each path in `request.sources` is
   canonicalized via `linkcertificate.canonical_path(context, source)` (resolving
   existing ancestor `realpath`s and folding slashes/case on Windows) and
   deduplicated in first-seen order. The authored spelling `source` is retained
   for compiler diagnostics and `__FILE__`. Committed artifacts are
   `<output_root>/.native/<sha256("native-c-source-path", canonical)>.{o,record}`;
   `<stem>.i`, `<stem>.d`, and any staged object are invocation scratch.
2. **Unconditional preprocessing (`native-preprocess`).** On every invocation,
   `compile_node` runs:

   ```sh
   <compile_argv...> -E -MD -MF <stem>.d -MT titan-native <source> -o <stem>.i
   ```

   It invalidates any prior memo for `<stem>.i`, parses `<stem>.d` with
   `depfile.parse`, and computes:

   ```text
   input = incremental.digest(context, "native-c-input", {
       source = source,
       argv = request.compile_argv,
       toolchain = request.toolchain,
       authored = incremental.file_digest(context, source),
       preprocessed = incremental.file_digest(context, "<stem>.i"),
       dependencies = certificate.files(context, files),
   })
   ```

   Running `-E` on warm invocations ensures that conditional compilation,
   command-line macro changes, newly shadowing headers, and negative
   `__has_include` branches change `preprocessed` or `dependencies` without
   requiring a directory walk of every `-I` root.
3. **Cacheability and hit check.** If `compile_argv` contains `@file`,
   `-fplugin*`, `-specs*`/`--specs*`, `-Xclang`, or `-wrapper`,
   `cacheable_policy` marks the node `cacheable = false`. Otherwise, when
   `request.incremental` is true, `<stem>.record` decodes via `graphcodec` as a
   valid `version.TITAN_NATIVE_RECORD_SCHEMA` (`"1"`) record with
   `record.input == input`, and `<stem>.o` is a regular file whose
   `incremental.file_digest` equals `record.object`, `compile_node` returns
   `{ path = object, identity = identity, source = source, hit = true,
   cacheable = true }` without invoking `-c`. Under `-v`, `titanc` writes
   `Titan native hit <source>` to `stderr`.
4. **Miss compilation and publication (`native-compile`).** On a miss (`Titan
   native miss <source>` under `-v`), `compile_node` reserves a sibling stage
   `<staged>`, runs `<compile_argv...> -c <source> -o <staged>`, re-reads and
   rehashes `source` and all `recipe.dependencies` in a fresh context to reject
   mid-compile edits, hashes `<staged>`, unlinks `<stem>.o` **first**, writes
   `<stem>.record` (or unlinks it if uncacheable), and renames `<staged>` to
   `<stem>.o` **last**.
5. **Scratch retirement.** On hits, misses, preprocessing or compile
   failures, and cancellation, one protected cleanup removes `<stem>.i`,
   `<stem>.d`, and any staged object. Committed `.o`/`.record` nodes are
   retained as shared cache entries; no invocation prunes nodes that it did
   not request.

In `titanc`, `-c --c-source <file>` is permitted without Titan module names for
standalone C helper preparation. Because the storage stem is derived from the
canonical source path, a moved checkout leaves the old nodes in place and a
consumer cannot select an object by enumerating `.native/`. With
`--print-c-objects`, `titanc` maps each `--c-source` argument through
`linkcertificate.canonical_path` to its certified node and, after releasing
its locks, writes the absolute object paths to stdout, one per argument in
argument order. In linking invocations, compiled `--c-source` objects are
placed at the start of `extra_objects`, before any `-X`/`--extra-object`
arguments.

## Final-link certificate and gate

`titan-compiler/linkcertificate.lua` caches final executable and library links
under `<output_root>/.titan-links/<key>/`, gated in `titanc`
before any test-runner rendering, entrypoint generation, static-archive probe,
or validation link.

### Output-set key and target directory

`linkcertificate.prepare(context, spec)` (`linkcertificate.lua`)
canonicalizes every entry in `spec.outputs`, rejects duplicates, sorts the
canonical paths, and hashes them with tag `"final-output-set"` to form the
64-hex directory key `key`. Canonicalization resolves each output's existing
ancestors through `realpath` but keeps the output's own leaf, so relative,
absolute, and symlinked-parent spellings of one destination share a key while
a symlink substituted for the output itself still fails the output snapshot.
Windows keys are further normalized to forward slashes and lowercase. The
record directory lives under the canonical output root. The owned output set
is:

* **Unix standalone or `--test` executable:** `{ path = program_path,
  executable = true }`, plus `{ path = program_path .. ".dSYM", kind =
  "directory" }` on Darwin;
* **Windows standalone or `--test` executable:** `{ path = paths.executable }`
  and `{ path = paths.provider }`;
* **Unix provider library:** `{ path = "<prefix>.so" }`, `{ path =
  "<prefix>.a" }`, optional `{ path = "<prefix>.so.dSYM", kind = "directory" }`
  on Darwin, and `{ path = shim.filename }` for each generated Lua shim;
* **Windows provider library:** `{ path = "<prefix>.dll" }` and each generated
  Lua shim.

Mutable runtime coverage outputs (`.gcda` files and rendered coverage reports)
are never part of `spec.outputs`. Each target owns
`<output_root>/.titan-links/<key>/` with:

* `record` — the `graphcodec`-encoded link certificate (`RECORD_LIMIT = 16 MiB`,
  schema `version.TITAN_LINK_RECORD_SCHEMA = "1"`,
  `digest = version.CERTIFICATE_DIGEST = "sha256"`,
  `canonicalization = version.CERTIFICATE_CANONICALIZATION =
  "titan-certificate-v1"`);
* `link.d` — the default linker dependency report path; and
* `synthetic/` — the target-isolated directory for the generated test runner
  source `<leaf>__test_runner.titan` and its generated C and object, the
  `<leaf>__test_entrypoint.c` or `<leaf>__entrypoint.c` entrypoint, and the
  Windows `.manifest`/`.rc`/`.res` resources named after that entrypoint,
  where `<leaf>` is the last component of the test or `main` root. They are
  generated only on a link miss, so an application and a test binary sharing
  an output root never overwrite each other's synthetic intermediates.

### Recipe, file digests, and native library policy

`prepare` hashes `input` with tag `"final-link"` over:

* `RECIPE_FIELDS` (`linkcertificate.lua`): `roots`, `entry` (`{ module,
  no_uv_bootstrap }`), `kind` (`"program" | "test" | "library"`),
  `no_uv_bootstrap`, `argv` (`driver.link_extra_flags()`), `toolchain`
  (`{ compiler = toolchain_identity, output_tools }`, see below), `test_cases`
  (deterministically sorted descriptors from `test_runner.discover`),
  `templates` (`configuration.compiler`, covering runner/entrypoint templates
  and `standalone_paths.lua`), `coverage` (`coverage.inventory`), `companions`
  (Windows launcher manifest and `relative_provider` path), `policy` (`{ uname,
  darwin, profile, target }`), `bindings` (`resolver_context.native_bindings`),
  `target`, and `environment` (`{ runtime_flags, MACOSX_DEPLOYMENT_TARGET,
  SDKROOT }`);
* `FILE_FIELDS` (`linkcertificate.lua`): `objects` (every linked
  module's primary `.o` and `.part<k>.o` files in bytewise module and part
  order), `c_objects` (`--c-source` objects), `payloads` (`-X` arguments in CLI
  order), `providers` (selected dynamic provider files), `archives` (selected
  static provider `.a` files), and `runtime` (`libtitan.a`, `libbacktrace.a`,
  `liblua.a`/`liblua55.a`). Every file in `FILE_FIELDS` is certified by its
  actual SHA-256 content digest via `incremental.file_digest`, never by
  timestamp or module recipe hash alone; and
* `native_policy` (`certificate.native_library_policy`,
  `linkcertificate.lua`):
  * If any `--c-source` object has `cacheable == false`, or if `argv`
    (with `-Wl,` lists expanded) contains `@file`, `-fplugin*`, `-plugin`/
    `--plugin*`, `-Xlinker`, `-specs*`/`--specs*`, `-wrapper`, or a
    `-filelist` option, the link is marked `cacheable = false` (`reason =
    "opaque linker input mechanism: ..."` or `"opaque native C input
    mechanism"`).
  * **`darwin` backend (`driver.IS_DARWIN`).** Appends
    `ticket.dependency_argv = { "-Wl,-dependency_info," .. dependency_file }`
    to the final executable or public DSO link. On commit,
    `native_dependencies` parses the binary `ld64` dependency stream (version
    `0x00`, `input-found = 0x10`, `input-not-found = 0x11`, `output = 0x40`)
    and hashes every `0x10` file not in `policy.exclude`.
  * **`gnu` / `lld` backend.** Selected on non-Darwin Unix by
    `driver.native_link_backend(context)` (`driver.lua`), which runs
    `<cc> -Wl,--dependency-file=<tmp> -Wl,--version` and recognizes `GNU ld`
    or `LLD` in the banner. The result is memoized per resolver context and
    persisted in `<output>/.titan/linker-feature`, keyed by the compiler argv,
    link flags, toolchain identity, and physical compiler and linker
    identities, so warm invocations skip the probe. When supported, appends
    `ticket.dependency_argv = { "-Wl,--dependency-file=" ..
    dependency_file }` to the final executable or public DSO link (never to
    archive-validation probe links). On commit, LLD's Make-escaped report is
    parsed with `depfile.parse`, while GNU ld's literal report is decoded from
    its trailing one-input-per-line phony-target stanza, preserving spaces,
    `#`, `$`, colons, and backslashes in paths.
  * **`compiler` fallback (`backend == "none"`, including Windows).** Parses
    `argv` with a finite grammar (expanding `-Wl,` comma tokens): ordered and
    repeated `-L`, `-l<name>`/`-l:<file>` with `-static` and forwarded
    `-Bstatic`/`-Bdynamic` selection, raw archive/object/import-library
    operands (each must be a regular file whose `incremental.native_input_kind`
    is an archive, object, or shared library), and the file-taking
    `--just-symbols` and `--retain-symbols-file` operands. Value-taking options
    such as `-u`, `-e`, `-soname`, `-install_name`, `-z`, and `--ld-path`, and
    input-free flags such as `-O<level>`, `-flto=<mode>`, and `-fuse-ld=`,
    are covered by the ordered recipe `argv`. Each `-l` library is searched
    directory by directory through the explicit `-L` directories, trying every
    candidate name in one directory before the next: on Windows (MinGW)
    `lib<name>.dll.a`, `<name>.dll.a`, `lib<name>.a`, `<name>.lib`,
    `lib<name>.dll`, and `<name>.dll` for dynamic selection, or `lib<name>.a`
    and `<name>.lib` for static selection. Otherwise the candidates are queried
    through `<compiler_argv> -print-file-name=<candidate>`; because separate
    queries do not reveal the compiler's directory order, candidates found in
    different implicit directories fail with `ambiguous compiler library search
    order: <name>`. Any other option, a text linker script, a
    thin archive, an unknown format, or an unresolvable library or file makes
    the link uncacheable (for example `unsupported native linker input
    mechanism: <flag>` or `cannot resolve native file: <path>`) instead of
    certifying an incomplete input set.

`output_tools` comes from `linkcertificate.output_tools(context, request)`,
whose request carries the exact compiler argv, ordered link flags, compiler
toolchain identity, compile prefix, the ordered linked inputs, and the
auxiliary tool roles the output kind actually uses (`ar` and `ranlib` for
Unix libraries, `rc` for Windows programs, `dsymutil` on Darwin), selected by
`driver.output_tool_descriptors`. The result records:

* `linker`: the linker the compiler driver really selects, with its exact
  driver argv and physical identity. Unless `-fuse-ld=`/`--ld-path` names it,
  `titanc` reads one read-only `<cc> -### -x c <null> -o <null>` job
  description: Clang names its configured linker directly, while GCC's
  `collect2` delegates to the linker named by the compiler. Fixed Darwin and
  Windows dependency-report policies skip only the capability probe, not
  linker resolution;
* each requested auxiliary role, with its exact argv and physical identity;
* every linker-stage program and plugin the job description names, whether
  or not LTO is enabled: GCC's `collect2` and any `-plugin`/`-lto_library`
  file it advertises (GCC passes `liblto_plugin.so` even to ordinary non-LTO
  links, and selects `collect2` even under `-fno-lto`); and
* only when LTO is enabled by the final flags, by compile-only `-flto`, or by
  an input whose recorded format is LLVM bitcode (or unknown), GCC's
  `lto-wrapper` and `lto1` stages, which an LTO-free link never runs.

A missing selected tool is an error.

Native input kind and LTO facts are cached by content digest in the
[persistent digest cache](incremental-compilation.md#persistent-digest-cache)
as optional additions to the existing schema; a missing fact is recomputed.

On a link hit, `linkcertificate.check` rehashes the exact library files
recorded in `record.native` (or `policy.files`). It does **not** rewalk
newly added files in earlier `-L` directories that were absent when the link
succeeded; adding a new shadowing library in an earlier `-L` directory
 without changing flags or existing library files requires a clean or forced
relink.

### Check, invalidation, and commit order

1. **Header restoration before check.** `titanc` runs
   `driver.prepare_foreign_headers` before `linkcertificate.check`, so deleted
   `.ffi.h` or `.titan.h` files are restored from module records even when the
   final link hits.
2. **Read-only check (`linkcertificate.check`, `linkcertificate.lua`).**
   Verifies `ticket.cacheable`, decodes `<ticket.record>`, checks
   `record_valid` (`schema`, `digest`, `canonicalization`), checks
   `record.input == ticket.input` and `#record.outputs == #ticket.outputs`,
   takes a fresh `output_snapshot` of every path in `ticket.outputs` (verifying
   non-symlink `file`/`directory` kind, `mode`, non-Windows executable bit
   `mode & 0x49 ~= 0`, recursive `.dSYM` directory entries, and SHA-256 content
   digests), and rehashes `record.native`. When all digests match, `check`
   returns `true`, `titanc` prints `Titan link hit <target>` under `-v`, and
   the invocation finishes.
3. **Pre-mutation invalidation (`linkcertificate.invalidate`,
   `linkcertificate.lua`).** On any miss, `titanc` prints `Titan link
   miss <target>: <reason>` under `-v` and calls `linkcertificate.invalidate`
   to unlink `<ticket.record>` before creating `<ticket.directory>`, removing
   any stale `link.d`, or synthesizing runner/entrypoint sources. The same
   invalidation callback is passed as `before_commit` into
   `driver.compile_program`, `driver.publish_windows_provider`, and
   `windows_publication.publish_program` (`titan-compiler/windows_publication.lua`,
   which stages and commits the Windows provider `.dll` before the `.exe`
   launcher and rolls back on caught failures).
4. **Post-publication commit (`linkcertificate.commit`,
   `linkcertificate.lua`).** Only after the final executable or
   provider bundle has been validated and published does `titanc` call
   `linkcertificate.commit`. Using a fresh context (`fresh(context)`), `commit`
   re-reads and rehashes every file in `FILE_FIELDS` (aborting with `link input
   changed during build: <field>` on any race), snapshots every published output
   in `ticket.outputs`, reads and hashes the linker dependency report
   (`native_dependencies`), and writes `<ticket.record>` last.

## Automatic test-root discovery

`testroots.discover(context, dirs, excludes, explicit_roots, source_path)`
(`titan-compiler/testroots.lua`, invoked by `titanc --test --test-dir`
at `titanc`) discovers test root modules from the filesystem without
reading or parsing `.titan` file contents. See also [Automatic test-root
discovery](test-runner.md#automatic-test-root-discovery).

### Naming convention, `--tree` containment, and traversal rules

* **CLI constraints.** `--test-dir <dir>` and `--test-exclude <module>` require
  `--test`, and `--test-exclude` requires at least one `--test-dir`
  (`titanc`). Every `--test-exclude` and explicit root must satisfy
  `staticmetadata.valid_module_name`.
* **Containment and prefix derivation.** Each `--test-dir` path must exist, be
  a directory (`context.io:stat`), and lie within at least one configured
  `--tree` root (`driver.TITAN_SOURCE_PATH`, checked lexically and via
  `context.io:realpath`). The **first** containing `--tree` root in
  `TITAN_SOURCE_PATH` order determines the directory's logical module prefix
  (`areas` in `testroots.lua`); `--test-dir` never adds a new `--tree`
  root or strips a leading `tests.` prefix. Repeated or equivalent directory
  spellings deduplicate by normalized relative base path.
* **Recursive walk and symlink policy.** `walk` (`testroots.lua`) lists
  each directory with `context.io:list`, sorts entry names with
  `util.bytewise_less`, calls `context.io:yield(directory)` between entries,
  and inspects each entry with `context.io:lstat`:
  * entries starting with `"."` (hidden files and directories) and names that
    are not valid module components are skipped;
  * a symbolic link whose name (or `<stem>.titan` stem) matches the test naming
    convention is followed with `context.io:stat` (reporting an explicit error
    on a broken link); unselected broken symlinks are ignored;
  * a directory entry is considered as a folder-module candidate, and if it is
    **not** a symbolic link (`not linked`), `walk` recurses into it; directory
    symlinks are never descended recursively (preventing symlink cycles),
    except when a symlinked directory is explicitly passed to `--test-dir`.
* **Final-component naming filter (`is_root_name`, `testroots.lua`).** A
  candidate module is selected only when its final dotted component is `test`,
  `tests`, `spec`, or `specs`, or ends in `_test`, `_tests`, `_spec`, or
  `_specs`.

### Resolver authority, shadowing diagnostics, and ordering

For every candidate matching `is_root_name` and not excluded (unless also
listed in `explicit_roots`), `consider` (`testroots.lua`) delegates to
`driver.resolve_source(context, logical, ...)`:

1. **Local root check.** Calls `driver.resolve_source(context, logical,
   source_root)` in the containing `--tree` root:
   * if `local_source.kind == "blocked"`, the file is an immediate contributor
     of a parent folder module and is silently skipped (the folder module
     itself is the compilation unit);
   * if the candidate was a directory entry and `local_source` is nil, not a
     `"folder"` module, or its `dirname(local_source.main)` differs from the
     directory, the directory is merely a namespace container (or shadowed by a
     sibling flat file) and is skipped without error.
2. **Global `--tree` check.** Calls `driver.resolve_source(context, logical,
   roots_text)` across the full `TITAN_SOURCE_PATH`:
   * if `source.kind == "blocked"`, discovery fails with
     `test module '<logical>' at '<physical>' is shadowed by folder module '<owner>' at '<main>'`;
   * if `source.main` lies outside every `--test-dir` discovery area (because
     an earlier `--tree` root shadowed it), discovery fails with
     `test module '<logical>' at '<physical>' is shadowed by '<main>'; reorder --tree roots or narrow --test-dir`;
   * if two discovery areas resolve the same `logical` name to different source
     descriptors (`not same_source_descriptor`), discovery fails with
     `ambiguous test module '<logical>': '<main1>' and '<main2>'`.
3. **Final root ordering and overrides (`testroots.lua`).**
   * Explicit positional CLI roots stay first in deduplicated CLI order, so an
     explicit first root (such as `test.tests` in the repository's native
     aggregate) continues to select the default executable/provider name when
     `--exe` is omitted, and an explicit root always overrides
     `--test-exclude`.
   * Automatically discovered roots not in `explicit` or `excluded` are sorted
     with `util.bytewise_less` and appended after `explicit`.
   * If the resulting `roots` list is empty, `discover` returns `nil, "no test
     modules found"`.
   * `discover` returns `roots, sources`, and `titanc` installs `sources` in
     `loader_options.source_overrides` so `build.run` reuses the already
     resolved descriptors without repeating directory walks.

Discovery is a pure filesystem inventory: it never reads `.titan` bytes, and
actual `test_*` case discovery still runs in `test_runner.discover` from
certified `record.object_metadata.test_functions` (or freshly checked ASTs on
misses). Selected modules with zero `test_*` functions are valid. While
`testroots.discover` reports errors from its own `--test-dir` `stat`/`realpath`,
`list`, entry `lstat`, and candidate-symlink `stat` calls (and reports vanished
selected files), candidate lookup itself uses the shared `driver.resolve_source`
helper, whose POSIX `regular_file` probe ignores `stat` errors on non-matching
candidate paths.
