# Issue 187: shared native standard-library validation

Base: `6e547a754` on `master`; implementation branch:
`codex/issue-187-shared-stdlib-tests`.

## Contract

Use one explicit 25-owner manifest on Linux, native CLANG64/UCRT Windows,
and macOS. Preserve the existing Unix assertions and the 53-case Windows
baseline (the issue's initial count was 44). Compile all portable fixtures
before using narrow classified skips. Preserve the existing process-group
and Windows Job Object supervision, pipe capture, native exit status, and
owned cleanup. Run Windows FS, SQLite, and local watchers on local NTFS.
Production APIs and provider identities are unchanged.

## Work sequence

1. Read issue, test ownership, build/SDK invariants, and applicable skills.
   Inspect existing dedicated Windows and Intel macOS VM execution paths.
2. Capture an unchanged Linux baseline from the base commit in an isolated
   checkout and prefix.
3. Share the inventory and complete-result audit. Port native synchronization,
   stdio, filesystem setup, command transport, and fresh-process fixtures.
4. Fold the Windows FS, IO, process, and SQLite owners into their ordinary
   owners, preserving Unicode/binary/locking/status coverage. Classify only
   genuine platform, probed-capability, or unsupported-production differences.
5. Run focused tests and the full shared aggregate, then full Linux regression
   and Linux CI. Run the complete common suite in local-NTFS Windows with
   current O0/O3 providers and in the existing Intel x86_64 macOS VM.
6. Independently review code and retained coverage; update both manuals and
   testing skill; make coherent commits and open a review PR. Leave it open.
   Do not merge or dispatch hosted macOS CI.

## Validation record

The task artifacts live under `/tmp/titan-issue187.HQ7st4B2` on the host.
`linux-baseline-tests.log` captures the unchanged mixed suite; focused and
post-change logs remain separate. Native validation receipts must record the
exact source snapshot/commit, OS/architecture, compiler/SDK/provider identity,
optimization flags, selected/pass/skip/fail totals and every named skip.
Current results are recorded in the final review PR after all gates finish;
intermediate canaries do not establish completion.
