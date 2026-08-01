# ASan uv callback and generated stack-base investigation

## Objective

Publish the conservative generated `_base` fix on a new feature branch before
attempting the flaky Linux sanitizer reproduction. While that pull request is
running in CI, reproduce the unfixed failure from `master` in an isolated
Ubuntu container, then rebuild the same container from the feature branch and
repeat the formerly failing case enough times to establish a clean after-state.

Do not bump the Titan ABI. Do not run macOS for this work. Use ordinary push CI
for the follow-up pull request and the local Ubuntu container for the explicit
before/after sanitizer reproduction.

## Current repository state

- Checkout: `/var/home/mascarenhas/Code/titan`
- Branch: `agent/rebase-after-foreign-calls`
- Base/master head: `029228a19c646224bc50ae39480bb799246c924a`
- PR #45 is merged into that base and supplies the generated-C diagnostic
  snapshots/reporting used by the reproduction.
- The `_base` fix and focused generated-C regression are being published in a
  new follow-up pull request from this branch.
- No callback-invariant diagnostic has been added.
- No reproduction container has been created. A read-only `podman ps -a` was
  the only Podman operation in the compacted conversation.

Merged PR #45 adds generated-C diagnostic snapshots/reporting and parks the
broad flaky filesystem sanitizer case with a `--filter-out`. Retain that work
while diagnosing; remove or revise the parking only after the real failure is
reproduced and fixed.

## Confirmed CI failure

Master run: <https://github.com/mascarenhas/titan/actions/runs/30707040644>

- Sanitizer job ID: `91387828555`
- Job: `sanitizer (ubuntu-24.04, focused-native)`
- Failing test:
  `spec/stdlib/fs_spec.lua:798: fs runtime covers modes, binary/NUL data,
  EOF/short reads, stat symlinks, permission errors, and paths`
- The child exited 134 with an ASan write SEGV.
- Top frames:
  - `titan_uv_fs_operation_deliverable_titan`, `titan/uv/file.titan:725`
  - `titan_uv_fs_dispatch_body_titan`, `titan/uv/file.titan:888`
  - `titan_uv_fs_dispatch_titan`, `titan/uv/file.titan:916`
  - `titan_uvshim_dispatch`, `titan-runtime/titan_uv.c:35`
  - `titan_uvshim_fs_cb`, `titan-runtime/titan_uv.c:110`
  - `uv__fs_done`, then `uv_run`
- Reported invalid write address: `0x530000005a38`.
- The preceding `uv_states` and timer tests passed. The remaining filesystem
  tests and delayed-filesystem callback tests also passed after the failed
  child process, so the failure is flaky and localized to that spawned test
  program.

The log can be retrieved without starting a workflow:

```sh
gh run view 30707040644 --repo mascarenhas/titan \
  --job 91387828555 --log-failed
```

## Mandatory execution order

1. Implement the conservative foreign-call `_base` refresh and focused
   generated-C regression on `agent/rebase-after-foreign-calls`.
2. Commit, push, and open a new follow-up pull request before any local
   sanitizer reproduction.
3. While push CI runs, switch the checkout back to `master` and build an
   isolated Ubuntu 24.04 sanitizer environment with Podman from the unfixed
   source.
4. Reproduce the actual ASan failure locally. Begin with the exact broad
   filesystem case in a loop; if it does not fail, run the original four-file
   shard in its original order. Repeat enough times to account for flakiness.
5. Save the failing output and generated-C/provider snapshots. Confirm that it
   is the same callback/write failure, not an unrelated container issue.
6. Switch back to the feature branch, rebuild the fixed sanitizer artifacts in
   the same container, and repeat the
   formerly failing local test/shard several times.
7. Run proportionate broader Linux tests, complete adversarial review, and
   update the follow-up pull request with the before/after evidence. Add the
   ASan-only callback invariants only if the reproduced evidence still makes
   the owner/state hypothesis live. Do not run macOS; its waiver is explicit.

If local reproduction remains elusive after a meaningful number of attempts,
do not silently call the issue fixed. Record the number and exact form of the
runs, preserve the diagnostic changes separately, and align with the
maintainer before treating absence of failure as evidence.

## Local sanitizer recipe

Use the checked-in sanitizer job in `.github/workflows/ci.yml` as the source of
truth. Its relevant environment is:

```sh
PREFIX=/workspace/titan/.lua
SANITIZER_FLAGS='-O0 -g -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer'
LUA_MYCFLAGS='-fPIC -O1 -g -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer'
LUA_MYLDFLAGS='-O1 -g -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer'
LUA_MYLIBS='-O1 -g -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer'
LIBBT_CFLAGS='-fPIC -O1 -g -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer'
LIBUV_BUILD_TYPE=Debug
LIBUV_BUILD_CFLAGS='-O1 -g -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer'
TITAN_EXTRA_CFLAGS='-O0 -g -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer'
TITAN_EXTRA_LDFLAGS='-O1 -g -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer'
ASAN_OPTIONS="detect_odr_violation=0:detect_leaks=1:detect_stack_use_after_return=1:halt_on_error=1:abort_on_error=1"
UBSAN_OPTIONS='halt_on_error=1:print_stacktrace=1'
TITAN_TEST_EXTRA_CFLAGS="$SANITIZER_FLAGS"
TITAN_TEST_EXTRA_LDFLAGS="$SANITIZER_FLAGS"
TITAN_TEST_UV_LATE_FS_ONLY=1
```

Build once in the persistent isolated container:

```sh
make lua
make libbacktrace
make libuv
make luarocks
"$PREFIX/bin/luarocks" install busted 2.3.0-1
PATH="$PREFIX/bin:$PATH" luarocks make --force
```

Run the single failing case first, without the branch's parking filter:

```sh
.lua/bin/busted -o gtest -v spec/stdlib/fs_spec.lua \
  --name='fs runtime covers modes, binary/NUL data, EOF/short reads, stat symlinks, permission errors, and paths'
```

If needed, reproduce the exact CI order, again without the broad-fs
`--filter-out`:

```sh
.lua/bin/busted -o gtest -v \
  spec/stdlib/uv_states_spec.lua \
  spec/stdlib/timer_spec.lua \
  spec/stdlib/fs_spec.lua \
  spec/stdlib/uv_late_callbacks_spec.lua \
  --filter-out='DNS'
```

Prefer an isolated copy/archive of the source rather than mounting the live
checkout read-write. Preserve the built container between attempts so the
expensive dependency build happens only once. The host has Podman, not Docker,
and the maintainer explicitly authorized using it outside the sandbox.

Avoid disassembly: it has repeatedly caused false-positive classifier blocks.

## Verified `_base` audit outside FFI

The following neighboring paths were audited against the current
`titan-compiler/coder.lua` after this plan was first written. They already
preserve `_base`; the missing conservative rebase is specific to foreign calls.

### First-class function values: all three dispatch branches

`codevaluecall` unconditionally sets `ctx.uses_base_off = true` at its entry
(`coder.lua:8810-8813`). That causes the containing generated function to save
`_base_off = savestack(L, _base)` in its preamble
(`coder.lua:14181-14185`; lambdas use the equivalent at
`coder.lua:14755-14759`).

The generated value-call dispatch has three branches:

1. exact-tagged Titan closure: unboxed native function-pointer call;
2. branded but non-exact Titan closure: strict Lua-stack entry through
   `luaD_callnoyield`;
3. genuine Lua/dynamic callable: ordinary Lua-stack entry through
   `luaD_callnoyield`.

All three converge on the same
`_base = restorestack(L, _base_off);` after the branch
(`coder.lua:9254-9307`). The slow branches preserve their call-frame base as a
separate `_vc_func` stack offset, use `restorestack(L, _vc_func)` for result
reads, and restore `L->top.p` from that offset before convergence
(`coder.lua:9163-9189`, `9277-9304`). The exact branch keeps fixed results in C
locals. Its flexible-result root publication does not trust raw `_base`; it
computes reserved slots through `stackslotat`, which itself uses
`restorestack(L, _base_off)` (`coder.lua:3041-3052`, `8507-8521`). Therefore
there is no uncovered exact/generic/Lua first-class branch in this respect.

### Method calls and method values

Ordinary record methods, static methods, and Interface method dispatch all flow
through `codecall`. After resolving the direct or Interface function pointer,
that lowering unconditionally sets `ctx.uses_base_off = true`, materializes the
native call, and emits `_base = restorestack(L, _base_off);` before result
projection or anchoring (`coder.lua:9348-9502`, `9645-9663`).

A bound method reference (`obj:m` as a value) creates an ordinary branded
`Type.Function` closure. Closure creation itself enables `_base_off` and
rebases immediately after `lua_pushcclosure` (`coder.lua:14581-14679`). Calling
that value then uses the same three-branch `codevaluecall` path described
above. The native bound-method trampolines tail-forward directly to the real
method and do not cache or subsequently use a caller `_base`
(`coder.lua:14335-14448`); Interface bound trampolines have the same property
(`coder.lua:15461-15618`). Their callers still perform the ordinary post-call
rebase.

### Loop GC checks

Every explicit loop-tail `luaC_checkGC(L)` is immediately followed by
`_base = restorestack(L, _base_off);`:

- `while`: `coder.lua:6645-6685`;
- `repeat ... until`: `coder.lua:6689-6721`;
- numeric integer/float `for`: `coder.lua:6756-6787`, with the shared check
  inserted in both emitted loop forms;
- generic `for`: `coder.lua:10836-10866`.

For `while`, `repeat`, and numeric `for`, the tail check is emitted only when
the generated loop body reserved allocation/root slots; that same condition
sets `ctx.uses_base_off = true`. Generic `for` enables `_base_off`
unconditionally before lowering and always emits the check/rebase pair. A
branch that exits before the loop tail also skips the GC call, so no rebase is
needed for a GC operation that did not occur. Calls within a condition,
iterator, or body remain responsible for their own immediate rebase.

The function/lambda entry `luaC_checkGC` is a different ordering and is also
safe: it runs before stack capacity is checked and before `_base` is captured
(`coder.lua:14194-14214`, `14763-14783`). Entry-level `try` moves that GC into
the protected body and explicitly rebases afterward (`coder.lua:10479-10543`).

### Remaining gap

`finish_foreign_call` (`coder.lua:8025-8057`) still neither enables
`ctx.uses_base_off` nor emits a rebase. When a foreign call has no post-call
statements it returns the C call as an expression, so the omission covers more
than the already-materialized post-call form. Both direct foreign calls and C
function-pointer calls use this helper (`coder.lua:8066-8172`). Any fix must
therefore materialize every potentially re-entrant foreign call, including the
no-poststats case, before it can restore `_base` safely.

The checker requires ordinary top-level variable initializers to be constant,
so direct foreign calls cannot reach the shared `initctx` variable-declaration
prologue. The valid zero-slot shape is an explicit final `do ... end` module
initializer that assigns module variables from scalar or void foreign calls.
`codeinitializerdec` already declares `_base` for zero slots and adds
`_base_off` whenever lowering sets `uses_base_off`; the generated-C regression
must exercise that shape rather than adding an unreachable special case to the
constant-variable initializer path.

## Hypothesis 1: stale generated `_base` after FFI

Generated Titan functions cache `L->top.p` in `_base`. Native Titan calls
already protect against movement: they save a stack offset and restore `_base`
after the call. Foreign calls do not currently do that.

Relevant compiler facts found before compaction:

- Native `codecall` marks `ctx.uses_base_off = true` and emits
  `_base = restorestack(L, _base_off);` after the call.
- `finish_foreign_call` in `titan-compiler/coder.lua` does neither.
- Both direct foreign calls and C-function-pointer calls pass through
  `finish_foreign_call`.
- That omission was historically plausible because Titan's early FFI could
  not call the Lua API.
- It is no longer safe as a general assumption. Foreign calls such as
  `uv_run`, `mco_resume`/`mco_yield`, Lua API functions, and `lua_checkstack`
  can re-enter execution, trigger GC, or otherwise relocate a Lua heap stack.
- `uv_run` is directly present below the failing callback stack.

The conservative candidate fix is:

- Make `finish_foreign_call` set `ctx.uses_base_off = true`.
- Materialize a non-void foreign result before rebasing.
- Emit `_base = restorestack(L, _base_off);` immediately after every foreign
  call, before any generated post-call stack-slot access.
- Handle void calls equivalently without inventing a result temporary.
- Cover direct foreign calls and function-pointer calls.

Add generated-C tests that prove the save/restore exists and that the restore
is ordered after the C call but before post-call Lua-stack accesses. Add a
runtime regression using a deliberately re-entrant/moving foreign operation if
one can be made deterministic and small.

## Hypothesis 2: wrong owner or Lua state in a libuv callback

All callbacks should execute against the main Lua state's `L`; Titan tasks run
later through `coroutine.resume`, never directly from a libuv callback. A
mix-up between the main state and a waiting task state, or between owners from
co-resident Lua states, could make an otherwise valid stack preamble write
through the wrong stack.

`titan-runtime/titan_uv.c` currently gets an owner from the libuv request or
handle data and decodes the callback `L` from owner slot 1. The owner protocol
has five slots:

0. native handle/request userdata
1. main Lua thread
2. Titan dispatcher closure
3. metadata
4. buffer/root

Add a private diagnostic enabled only in the sanitizer build, for example
`TITAN_UV_ASAN_INVARIANTS=1` supplied through that job's
`TITAN_EXTRA_CPPFLAGS`. Do not expose it in public `titan/uv.h` and do not
change public callback signatures or ABI.

At the very beginning of the private dispatch path, before unchecked
`thvalue`, `clCvalue`, `uvalue`, or `pvalue` reads, validate in stages:

- owner is non-null and is a userdata with exactly the five expected slots;
- native slot is full userdata and its payload address equals the callback's
  original libuv request/handle pointer;
- main slot is a thread and the decoded state equals `mainthread(G(L))`;
- dispatcher slot is a C closure with the expected Titan closure layout and
  brand before reading its upvalues;
- metadata has the expected userdata shape;
- buffer is nil or has the expected userdata shape;
- optionally, after proving the state identity, check coherent
  `stack <= top <= stack_last` bounds.

Pass the original callback-native pointer into the private static dispatch
helper at each callback call site. Keep all checks and extra includes behind
the private macro. On failure, print a compact reason, event, owner pointer,
and native pointer to stderr, flush, and abort. Never `luaL_error` or longjmp
through libuv; do not rely on `assert` because it may compile away.

Focused source-contract coverage belongs in
`spec/stdlib/uv_native_handles_spec.lua`. Workflow-policy coverage belongs in
`spec/libuv_build_spec.lua`. The private macro should be present only in the
Linux sanitizer job.

## Why the generated preamble itself is not the primary suspect

The observed generated preamble performs:

1. `luaC_checkGC(L)`
2. stack-capacity check / `lua_checkstack`
3. capture `_base = L->top.p`
4. reserve stack slots
5. initialize the newly reserved slots to nil

There is no call between capturing `_base` and the nil-initialization loop.
`TITAN_UNLIKELY` is only a branch prediction hint around `lua_checkstack`; it
does not change the call's semantics. Lua's legitimate `stack_last` updates
are centralized in stack initialization/reallocation and maintain coherent
stack pointers. This makes a stale caller `_base` across an earlier re-entrant
FFI call, or a wrong callback state/owner, more plausible than the local
preamble ordering.

## Validation and delivery

After a confirmed local before/after result:

- Run focused coder tests for foreign-call code generation.
- Run `spec/stdlib/uv_native_handles_spec.lua` and
  `spec/libuv_build_spec.lua`.
- Repeat the formerly failing ASan case several times in the same Ubuntu
  container; then repeat the original timer/fs shard several times if time
  permits.
- Run the strongest practical ordinary Linux suite because compiler codegen is
  affected (`make test` is preferred when feasible).
- Check the complete diff for exploratory changes; the maintainer explicitly
  asked that earlier speculative fixes remain undone.
- Perform an adversarial review before the final PR update.
- Open and update a new follow-up PR; PR #45 is already merged.
- No ABI bump and no macOS run.

This is an internal correctness/diagnostic change, not a user-visible language
feature, so the language and implementation manuals are not expected to need
updates. If the final fix changes a documented FFI invariant, update the
relevant implementation documentation only. Update the sanitizer-policy text
in `AGENTS.md` if the ASan-only callback macro is retained.
