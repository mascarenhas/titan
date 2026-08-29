# Libuv work queue and exportable C built-in types

## Delivery scope

- Implement [issue #113](https://github.com/mascarenhas/titan/issues/113) on
  `codex/issue-113-libuv-work-queue`, based on `origin/master` at
  `54ba8fd6`.
- Keep GitHub Project 3 item `PVTI_lAHNAWvOAYauQM4OFZjr` in **In progress**
  during implementation and move it to **In review** only after the pull
  request's Linux and coverage checks are green.
- Add the contextual, target-profile C built-in type spellings described by the
  issue and make only their self-contained structural closures legal in public
  module interfaces.
- Add `async.run_foreign(f: foreign (*void) -> (), arg: *void)` using
  `uv_queue_work` without allowing libuv's worker thread to inspect Lua or
  Titan-managed state.
- Remove the primitive `titan_ffi_*` aliases from `titan-runtime/titan/ffi.h`
  and migrate their standard-library clients to the new spellings.
- Update the language and implementation manuals and the `titan-programmer`,
  `titan-async`, and `titan-ffi` skill cartridges in the same change.
- Add compiler regressions to the existing Lua/Busted layers and runtime
  behavior to the native Titan standard-library suite. Do not add a Lua
  boundary suite for `async.run_foreign`.
- Do not dispatch the explicitly waived macOS workflow.

## Type contract

### Contextual spelling

- Parse these as C types only in a type position, without adding lexer keywords:
  `void`, `bool`, `char`, `signed char`, `unsigned char`, `short`,
  `unsigned short`, `int`, `unsigned int`, `long`, `unsigned long`,
  `long long`, `unsigned long long`, `foreign float`, `double`, and
  `long double`.
- Map `bool` to C99 `_Bool`; keep Titan `boolean` distinct. Map
  `foreign float` to C `float`; keep Titan `float` distinct.
- Resolve size, rank, and signedness through the compiler's active C target
  profile instead of assuming the host ABI.
- Keep all contextual component words available as ordinary identifiers where
  the grammar is not reading a built-in C type. Diagnose attempts to establish
  a new nominal Titan type with one of the contextual built-in names so a
  declaration cannot create a misleading or unusable shadow.
- Render diagnostics and pretty-printed Titan types with the Titan source
  spellings (`bool` and `foreign float`) while retaining canonical C spellings
  for generated C declarators.

### Public interface boundary

- Rename `types.first_c_ffi_type` to
  `types.first_non_exportable_type` and change the predicate's meaning rather
  than retaining the old “all C is forbidden” behavior.
- Permit `CVoid`, target-profile `CInteger`, and target-profile `CFloat`, plus
  recursively well-formed `CPointer`, `CFunction`, and `COwned` graphs built
  only from those leaves.
- Keep every imported `CTypedef` non-exportable even when its transparent
  target is an otherwise allowed primitive. Also reject header-dependent
  structs, unions, fields, arrays, enum identities, C modules, legacy pointer
  wrappers, and any allowed constructor containing a rejected descendant.
- Preserve ordinary Titan visibility filtering: local fields, variants,
  methods, and declarations do not become public merely because their type is
  exportable.
- Serialize the allowed descriptors without `_ffi_scope`, origin-header,
  probe, or other compiler-only state. Validate deserialized descriptors as a
  closed hostile-input schema before code generation, including dense lists,
  exact fields/qualifiers, canonical primitive identities, non-variadic C
  functions, and the recursive exportability rule.
- Ensure C-containing function tags and owned-storage metatables use a stable
  cross-module identity for exported structural built-ins, while preserving
  module-local identity for imported typedef-bearing types.
- Keep dynamic/Lua conversion unavailable for raw C pointers and foreign
  function pointers; an exported native signature enables statically compiled
  Titan consumers and does not invent a Lua representation.

## `async.run_foreign` ownership contract

- Expose exactly
  `function run_foreign(f: foreign (*void) -> (), arg: *void)` from
  `titan.async` and route it through the private `titan.uv` task runtime.
- Allocate one request owner for a submitted work item. It owns the
  `uv_work_t`, the raw callback/argument carrier, and the main-loop completion
  callback state; `Task.pending` roots that owner until completion.
- Store only raw C fields needed by the worker callback (`f` and `arg`) in the
  carrier. Any pointer used solely by the after-work callback may be present in
  the carrier, but the worker callback must neither dereference it nor call any
  Titan/Lua/compiler-generated helper other than the supplied raw C function.
- The worker callback performs exactly `f(arg)` and returns. It does not
  allocate, raise, resume a Task, touch a `TValue`/`Udata`, use the Lua API, or
  read Titan-managed fields.
- The `uv_after_work_cb` runs on the event-loop thread, recovers the rooted
  request owner, copies the status/result needed after cleanup, and resumes the
  Task successfully for status zero or raises a descriptive error for a
  nonzero status.
- Treat every nonzero `uv_queue_work` submission status as synchronous
  rejection: clear `Task.pending`, release the complete owner, and raise
  without expecting a callback.
- Once submission succeeds, the completion callback is authoritative. Do not
  free request state early and do not use `uv_cancel` as a substitute for
  completion; normal Task cancellation is injected when the callback resumes
  the waiting task.
- Rely on the suspended native caller frame to keep an owned `arg` allocation
  alive, as specified by the issue. Document that callers remain responsible
  for synchronization and that the API is for blocking foreign-library calls,
  not arbitrary background Titan code.

## Production changes

### Parser, checker, and type model

- Parse each contextual C built-in as the canonical complete spelling in the
  existing `TypeName` node, ahead of the ordinary single-name alternative.
  Reusing `TypeName` is intentional: contextual built-ins participate in the
  same transparent-alias lookup and shadowing order as ordinary named types,
  while a distinct AST node would bypass that invariant.
- Lower the recognized canonical names through the active C probe profile to the existing
  `CVoid`/`CInteger`/`CFloat` descriptors.
- Reject contextual built-in names at the nominal declaration boundary without
  reserving them in expressions, locals, fields, parameters, or module member
  names.
- Implement the new non-exportable-type walk and update interface projection,
  serialization, runtime identity, and diagnostics to use it.
- Extend binary interface serialization and hostile metadata validation with
  only the allowed C descriptor constructors.

### Runtime and standard library

- Add the smallest private C carrier/helper declaration needed by
  `uv_queue_work`; do not publish primitive convenience aliases or a new child
  DSO.
- Add the work-call variant, dispatch path, owner, worker callback, after-work
  callback, synchronous rejection path, and public facade function.
- Replace standard-library uses of removed primitive aliases with the exact new
  contextual spellings. Retain deliberate test-local typedef fixtures whose
  purpose is to verify that imported typedefs remain non-exportable.
- Regenerate or deliberately update checked-in standard-library metadata and
  source fixtures that encode the affected public interfaces.

## Test plan

### Compiler and language regressions (Lua/Busted)

- Parser coverage for every accepted spelling, pointer/const-pointer/owned and
  foreign-function compositions, ambiguous prefixes, and continued use of the
  contextual words as ordinary names.
- Checker coverage for target-profile lowering, legal public variables,
  functions, aliases, fields, variants, and methods; nominal-name rejection;
  and continued rejection of imported typedefs and header-dependent C shapes.
- Type-layer truth tables for `first_non_exportable_type`, serialization
  round trips, C-vs-Titan distinction, stable structural equality/identity,
  and nested accepted/rejected graphs.
- Driver/interface coverage for producer-to-consumer use of public built-in C
  types and hostile serialized schemas (unknown spellings, inconsistent
  integer profile fields, invalid qualifiers/lists/ABI, typedef smuggling,
  cycles, and compiler-only state).
- Coder coverage that compiled consumers call exported foreign signatures and
  exchange pointers/owned storage correctly, while Lua/dynamic ingress remains
  rejected at the established boundary.
- Update existing FFI, metadata, generated-name, and libuv structural tests
  whose expectations intentionally change.

### Native standard-library regressions

- Add a source-defined C worker function and synchronized native fixture that
  blocks on a C synchronization primitive, proving the event loop continues to
  run while `run_foreign` waits and that the raw argument is delivered.
- Verify completion ordering and result visibility with explicit
  synchronization rather than a data race.
- Exercise cancellation after accepted submission and prove the carrier and an
  owned argument remain alive through the authoritative after-work callback.
- Keep all behavioral cases in `spec/stdlib/titan`; use Busted only for
  compiler/metadata/build-structure assertions.

## Documentation and skills

- Update `doc/language/ffi.md` with the contextual spellings, generated C
  mapping, exportable structural closure, typedef exception, Lua-boundary
  limitation, and examples.
- Update the async language documentation with `run_foreign`, intended use,
  ownership, synchronization, cancellation, and worker-thread restrictions.
- Update the implementation FFI/type-metadata documentation for parsing,
  target-profile lowering, serialization/validation, and cross-module runtime
  identity.
- Update the libuv runtime/extension documentation for request ownership,
  worker/after-work thread separation, submission failure, and completion.
- Update `titan-programmer` with the user-level vocabulary/routing summary,
  `titan-ffi` with authoring/export/Lua-boundary rules, and `titan-async` with
  the exact API and runtime ownership protocol. Validate all three skill
  directories with the skill-creator validator.

## Validation and publication

1. Run focused parser, checker, types, driver/interface, coder/FFI, and libuv
   Busted files with `TITAN_PROBE_CACHE_DISABLE=1`.
2. Build and run the focused native async suite with an isolated absolute
   prefix under `/tmp` and the appropriate `TITAN_FILTER`.
3. Run syntax/metadata regeneration checks and the three skill validators.
4. Run the complete canonical `make test` from a fresh isolated prefix with no
   ambient `ROCKS_TREE`, `TITAN_ROCKS_ROOT`, `TITAN_EXTRA_CPPFLAGS`, or
   `TITAN_NO_LINE_DIRECTIVES`.
5. Review the complete diff independently for parser ambiguity, hostile
   metadata acceptance, cross-module identity, stale generated artifacts,
   worker-thread Lua/Titan access, request lifetime, and cancellation cleanup.
6. Commit, push the branch, open a PR that closes #113, and monitor the regular
   push-triggered Linux jobs and Codecov result. Do not dispatch macOS.
7. After every required PR check is green, verify the project item still points
   at issue #113 and set its status to **In review**. Re-read the item to prove
   the final state before marking the goal complete.

## Progress log

- 2026-08-28: Read issue #113 and its Project 3 item, moved the item from
  **Ready** to **In progress**, fetched `origin/master`, and created
  `codex/issue-113-libuv-work-queue` at `54ba8fd6`.
- 2026-08-28: Read the mandatory programmer/tester/async/FFI cartridges and the
  skill-creator instructions; began source, test, documentation, and migration
  reconnaissance.
- 2026-08-28: Implemented the compiler/interface, async runtime, native tests,
  standard-library migration, documentation, and skill updates. An independent
  review tightened structural type identities, recursive portability, hostile
  metadata validation, and alias precedence before integration testing.
- 2026-08-28: A clean provider build found the intended `char` value precedence
  colliding with allocation pseudo-members in the shared `titan.string` folder;
  captured the contextual type as private `CChar` and added a focused checker
  regression before resuming the full suite.
- 2026-08-28: Independent boundary review found that callback-pointer results
  need a pre-call Lua-entry rejection and that hostile compiled metadata must
  preserve the source checker's `TValue`-slot boundary. Added both defenses and
  regressions for module variables, record fields, union payloads, and interface
  fields; the focused driver/checker/coder run passes 148 checks.
- 2026-08-28: Two independent final reviews are clean. The first complete
  sharded run passed the retained runtime/packaging gate (127 checks) and
  isolated two stale pre-extension assertions: portable owned-C identities now
  use their canonical serialized key, and portable `CInteger` is no longer a
  hostile interface descriptor. Updated both tests to assert the new boundary;
  their complete files pass 54 checks and targeted rereview is clean.
- 2026-08-28: Final local validation passes: 127 retained Busted checks, all
  four isolated compiler shards (117 files and 3,223 checks), and all 205 native
  Titan standard-library tests. The sandboxed native attempt demonstrated its
  expected socket `EPERM` boundary; rerunning the same built executable with
  localhost/PTY access passed 205/205. A final feature filter passes all three
  `async.run_foreign` tests.
