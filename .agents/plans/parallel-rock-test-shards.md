# Parallel local rock-test compiler shards

## Objective

Reduce the unfiltered local `luarocks test` / `make rock-test` wall time by
running the Busted compiler/language specs in the repository's existing four
measured shards. Preserve the current serial behavior for filtered or otherwise
custom Busted invocations, keep the retained runtime/packaging Busted specs
single-run, and leave Linux coverage CI unchanged.

## Research findings

- `rock-test` currently runs one `busted-test` process before the aggregate
  native Titan suite. `run_rock_tests.sh` preserves LuaRocks-forwarded Busted
  arguments and keeps `BUSTED_FILTER` and `TITAN_FILTER` independent.
- `ci_compiler_test_groups.txt` is already an exhaustive four-way partition of
  all compiler/language specs. `ci_test_groups.sh` validates that manifest and
  can select covered shards, but its uncovered mode currently selects only the
  entire compiler set.
- Compiler specs reuse checkout-root artifact names. Four Busted processes in
  one checkout would race. The Linux coverage runner avoids this by extracting
  private prepared-checkout workers, giving each a private `TMPDIR`, and
  bounding nested Make/Titan compilation to one slot.
- The eight `STDLIB_BUSTED_TESTS` are deliberately outside compiler coverage
  and must still run exactly once. Local runs need no LuaCov collection or
  statistics merge.
- A snapshot of the live prepared checkout must preserve tracked edits,
  deletions, untracked fixtures, ignored build inputs, modes, and timestamps.
  Git archives/worktrees are therefore insufficient. Exclude the repository
  metadata, nested libbacktrace metadata, the shared `.lua` prefix, and the
  external worker root.
- The local launcher must remain compatible with the macOS Bash 3.2 userland
  even though macOS CI does not invoke `rock-test`.

## Implementation plan

1. Extend `spec/support/ci_test_groups.sh` to accept
   `compiler-uncovered-shard-{1..4}`. Reuse the existing manifest selection and
   exhaustive validation, but run the selected files without `-c` or any
   LuaCov output.
2. Add a local parallel Busted launcher under `spec/support/` that:
   - validates `TITAN_ROCK_TEST_JOBS` as an integer from 1 through 4, default 4;
   - resolves the Busted executable and temporary root to absolute paths;
   - snapshots the current prepared checkout once, outside that checkout;
   - extracts four independent workers without `.git`, `libbacktrace/.git`, or
     `.lua`;
   - gives every worker its own `TMPDIR` and `CCACHE_TEMPDIR`, while retaining
     the caller's shared ccache contents, and runs its uncovered shard with
     `MAKEFLAGS=-j1` and `TITAN_JOBS=1`;
   - schedules at most the configured number of workers, retains tagged logs
     and exact statuses, waits for every launched shard, and fails if any test
     or logging stage fails;
   - terminates worker process groups and removes the exact temporary tree on
     normal exit or HUP/INT/TERM.
3. Split the Make entry points so the unfiltered path runs the eight retained
   runtime/packaging Busted specs serially, then the new parallel compiler
   launcher, then the existing native aggregate. Route any nonempty
   `BUSTED_FILTER` or forwarded Busted argument through the existing single
   Busted invocation byte-for-byte. A `TITAN_FILTER` by itself still permits
   compiler sharding.
4. Add focused Busted harness coverage for dispatch, argv preservation,
   manifest exhaustiveness, no-LuaCov uncovered shards, worker isolation,
   default four-way concurrency and a lower job bound, invalid bounds,
   failure propagation/native gating, logs, and interrupt cleanup.
5. Update the README and repository guidance that currently state local Busted
   runs are always serial. Do not alter the Linux coverage runner, its two-way
   concurrency cap, the workflow, or Codecov behavior.

## Validation and review

- Run syntax/static checks for every changed shell/Lua file and `git diff
  --check`.
- Run the focused harness regressions, then the complete relevant root spec.
- Exercise the real unfiltered four-shard compiler path using the isolated
  issue-86 installation, followed by the native aggregate through `rock-test`.
- Inspect process cleanup and the absence of coverage artifacts in local
  workers.
- Obtain an independent adversarial review before committing this as a
  separate harness commit on `codex/issue-86-map-metamethods`.
- Push, update PR #88, then require the new exact head's Linux jobs and merged
  Codecov gate to pass. Do not manually trigger macOS for this PR.
