# Task resumption tokens

## Delivery scope

- GitHub Project item `236740322` is Titan issue #115, "Task resumption
  tokens". The card was moved from **Ready** to **In progress** before source
  work began.
- Work happens on `codex/task-resumption-tokens`, branched from the verified
  `origin/master` commit `522368faa132dbf58773ce5ffcb319f7f384d4a5`.
- Keep `TITAN_VERSION=0.6.0` and `TITAN_ABI_VERSION=2` unchanged. The project is
  still pre-release and the issue explicitly waives a language-version bump.
- Deliver the code, native Titan regressions, human-facing language and
  implementation documentation, and the agent-facing `titan-async` cartridge.
  Publish only after focused and full local validation plus independent review.
  Run and monitor Linux CI and Codecov, but do not dispatch macOS CI.

## Contract to implement

- Declare public nominal `uv.ResumeToken` as a record with one
  `const source: string?` field, and re-export it as `async.ResumeToken` so
  applications never need the private `uv` module.
- Change the public APIs to:

  ```text
  async.suspend(token: ResumeToken,
                cancel_action: SuspendCancelAction?)
  Task:resume(token: ResumeToken)
  ```

- Carry the token in `SuspendCall` and store the currently accepted token in a
  new local optional `Task.resume_token` field. Clear it when the explicit
  suspension is actually retired.
- `Task:resume` compares nominal record identity with the stored token before
  scheduling or coalescing a wake. A mismatch raises synchronously in the
  caller and reports the expected token's `source`, using `"unknown source"`
  when there is no source. The target Task remains suspended and unchanged.
- Resume tokens authorize only the public `Task:resume` wake installed by the
  current `async.suspend`. They are not a general mechanism for completing a
  Task that is waiting on a native operation or persistent callback source.
- Cancellation of `async.suspend` runs the caller's optional detach action and
  requests the target-owned deferred wake with the stored token. Native
  callback completion continues to use the source-private callback-resume path;
  it does not acquire a public token API.
- Preserve the cooperative/non-reentrant Runtime, target-owned zero-timer
  delivery, close-before-resume lifetime, repeated-correct-token coalescing,
  and first-reason cancellation behavior.
- Once private tokens are installed, remove defenses in the current stdlib
  clients that existed only because an arbitrary Task holder could wake them:
  channels suspend once instead of rechecking full/empty in a loop, and
  combinator listeners capture the current Task directly instead of retaining
  an optional `waiting` sentinel. Preserve `winner`, `rejected`, and completion
  counters that arbitrate legitimate multiple terminal-listener deliveries.
  The retained `join*` per-position `has_finished()` checks are unrelated local
  idempotence, not premature-resume guards.
- Apply the same refactor to the filesystem clients. An accepted `realpath`
  request has one authoritative callback and therefore suspends once without a
  completion flag. Each blocking `Watcher:poll` creates and stores a fresh
  private token, then suspends once: a native callback has already buffered a
  notification, while the facade wake has already removed the last
  registration. The documented external-coordination requirement excludes a
  concurrent mutator from invalidating that postcondition before delivery.

## Production changes

1. `titan/uv/task.titan`
   - Add `ResumeToken`, the `SuspendCall.token` field, and
     `Task.resume_token`.
   - Update Task constructors, `Task:resume`, `SuspendCall:dispatch`, low-level
     `suspend`, and callback retirement.
2. `titan/async.titan`
   - Re-export `ResumeToken` and update the public `suspend` facade.
   - Give each channel instance one private token shared by its send, receive,
     and close closures.
   - Give each fixed-arity any/race/all/join invocation a fresh private token
     shared by its listener closures and the one suspension.
   - Remove the channel condition re-suspension loops and every combinator
     optional-waiter sentinel made obsolete by private wake ownership. Retain
     winner/rejection/counter arbitration, while leaving `join*` slot
     idempotence outside this refactor.
3. `titan/fs.titan`
   - Give each `realpath` wait a fresh token and suspend exactly once; remove
     the obsolete request completion flag and loop.
   - Give each blocking Watcher poll a fresh token stored only for that active
     waiter and ordinary Task wake, clear both together before delivery, and
     suspend exactly once. Keep native callback delivery on the existing
     private callback helper.
4. Update source-contract assertions and pinned standard-library metadata
   fixtures for the changed public nominal/signatures.

## Test plan

- Keep public behavior under `spec/stdlib/titan/`, outside LuaCov.
- Extend the owning uv/async Task tests to prove:
  - a matching token wakes only after the resumer returns and repeated matching
    requests coalesce;
  - a distinct record with the same source is rejected by identity;
  - mismatch raises in the resumer, leaves the target waiting, and reports the
    stored source;
  - a nil stored source reports `"unknown source"`;
  - a stale token cannot wake a later suspension guarded by another token;
  - `Task:resume` with any token rejects a Task waiting for an ordinary native
    callback, including after an explicit suspension resumes into that wait,
    and that callback still completes the Task normally;
  - cancellation still runs the detach action synchronously and wakes with the
    accepted token.
- Update channel tests so an unrelated holder cannot directly wake a blocked
  sender or receiver with its own token, while legitimate channel progress and
  close still wake waiters.
- Update filesystem condition-waiter tests for token-protected one-shot
  explicit and Watcher suspensions, preserving callback/direct-wake,
  cancellation, repeated-poll, and clear-wake coverage.
- Update the retained `spec/libuv_build_spec.lua` structural contracts and
  metadata fixtures, then run its focused cases.

## Documentation and skill plan

- Update `doc/language/async-io.md` with the public record, exact signatures,
  identity/provenance/error semantics, channel/combinator private-token
  guidance, and examples.
- Update `doc/implementation/libuv-runtime.md` with `SuspendCall` propagation,
  Task storage/retirement, caller-side mismatch behavior, cancellation, and
  high-level private-token ownership.
- Repair related exact signatures or recipes in `doc/language/generics.md`,
  `doc/implementation/generics.md`, `doc/style-guide.md`,
  `doc/implementation/libuv-extension-guide.md`, and
  `doc/implementation/filesystem-library.md` where they would otherwise teach
  the removed tokenless API.
- Update `.agents/skills/titan-async/SKILL.md` throughout: inventory,
  suspend/resume model, channel/combinator recipes, examples, review checklist,
  and evaluation cases. Run its `EVALUATION.md` routing/lightweight checks if
  executable commands are provided.

## Validation and publication

1. Syntax/source inventory checks and focused native filters for resume-token,
   channel, filesystem-waiter, cancellation, and continuation behavior.
2. Focused `spec/libuv_build_spec.lua` contracts and metadata checks.
3. Full native stdlib aggregate, then canonical fresh-prefix `make -j2 test`
   with ambient provider/path policy variables cleared.
4. Independent implementation/runtime review and independent human-doc/skill
   review; address all material findings and rerun affected gates.
5. Confirm diff, version/ABI invariants, clean worktree, and branch commits;
   push and open a PR linked to issue #115.
6. Monitor all push-triggered Linux jobs and Codecov project/patch checks until
   green. Do not dispatch `workflow_dispatch` or macOS. Re-verify PR mergeability
   and Project status after linking, then move the card to **In review**.

## Progress log

- 2026-08-28: resolved the numeric Project item to issue #115; confirmed no
  comments or extra labels; moved the card to In progress; verified clean
  `master` and matching remote baseline; created the feature branch; read the
  required programmer, async, and tester cartridges; mapped the initial
  production, test, documentation, structural-spec, and metadata-fixture scope.
- 2026-08-28: maintainer reconfirmed that tokens guard only `Task:resume` for
  `suspend`; native callback resumption and cooperative scheduling remain a
  separate source-private mechanism.
- 2026-08-28: maintainer added a refactor requirement to remove channel and
  combinator defenses whose sole purpose was surviving an unauthorized early
  public resume; multi-listener arbitration and correct-token coalescing remain.
- 2026-08-28: implemented the nominal public token API, identity-first caller
  error, captured-token cancellation, deferred coalesced delivery, and shared
  clear-before-user-code/terminal-listener retirement. Native operation and
  persistent-source callbacks remain on their private tokenless path.
- 2026-08-28: assigned private tokens to channels, every fixed-arity
  any/race/all/join invocation, `fs.realpath`, and Watcher polling. Removed the
  channel re-suspension loops and all 17 combinators' nullable waiter sentinels,
  preserving independent winner/rejection/counter arbitration.
- 2026-08-28: added native identity, mismatch, stale-token, wrong-time,
  native-wait, channel, filesystem, cancellation, and deferred/coalescing
  regressions; added the structural clear-before-terminal-listener oracle.
  Regenerated the canonical `titan.uv` and eighteen-module metadata fixtures;
  the final provider reproduces both byte-for-byte (`titan.uv`: 6829 bytes,
  SHA-256 `a387163e80e9fb64ae830f438b3ecfa060b6f6b4f5724830bb3251bfa9c8d789`).
- 2026-08-28: documented the public and private contracts across README,
  language/implementation manuals, filesystem docs, style guidance, AGENTS,
  and the programmer/async/networking cartridges. Independent implementation,
  refactor-scope, test, documentation, and final holistic reviews are clean
  after fixing allocation-before-publication, terminal-listener retirement,
  and stale-protocol prose findings.
- 2026-08-28: final isolated-prefix validation passed: 126 retained
  runtime/packaging specs, all four complete compiler/language shards, and the
  202-test native aggregate. `TITAN_VERSION=0.6.0` and
  `TITAN_ABI_VERSION=2` remain unchanged; macOS was not dispatched.
- 2026-08-28: maintainer follow-up identified the remaining defensive
  resuspension loops in `fs.realpath` and `Watcher:poll`. Revalidated their
  one-shot callback/facade postconditions and expanded this plan to remove the
  loops, make the active Watcher token fresh per blocking poll, and clear that
  token with its exact waiter.
- 2026-08-28: completed both filesystem follow-ups. `fs.realpath` now installs
  its cancellation action before native acceptance and suspends exactly once;
  every blocking `Watcher:poll` owns a fresh token, clears the exact waiter/token
  pair before delivery, and suspends exactly once. Added wrong-token, stop-wake,
  reuse, and structural regressions; updated both filesystem manuals and the
  async cartridge. The focused structural spec, complete 52-case libuv build
  spec, focused and full filesystem filters, standalone 202-test aggregate, and
  canonical fresh-policy `make -j2 test` all pass (127 retained specs, all four
  compiler/language shards, and 202 native tests). Three independent reviews
  are clean; the async cartridge has no separate `EVALUATION.md`; macOS remains
  undispatched.
