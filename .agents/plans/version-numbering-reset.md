# Titan version-numbering reset

## Goal

Separate Titan's compiled-module ABI identity from the compiler and standard-
library release version before the public release:

- `TITAN_ABI_VERSION` is the monotonic ABI integer `2` and is used only for
  compatibility markers and native-build cache namespaces.
- `TITAN_VERSION` is the semantic release version `0.6.0`.
- the release's derived major/minor component, `0.6`, owns installed library
  and compiler-data paths, the installed runtime SDK archive, and the versioned
  `TITAN_PATH_0_6` override.

There are no compatibility or migration requirements for existing Titan
installations. Documentation must describe only the reset numbering and must
not retain historical Titan release or ABI numbers.

## Invariants

1. Generated dynamic and static module metadata carries only
   `TITAN_ABI_VERSION`, and every loader rejects a nonmatching ABI before
   decoding types or linking native payload.
2. Runtime and compiler constants agree on all three identities: ABI, full
   semantic version, and derived major/minor library version.
3. Library search, canonical provider publication, staged compiler data,
   the installed runtime SDK archive, generated Lua C-path configuration, and
   versioned environment overrides use the major/minor library version, never
   the ABI. The SDK archive is `lib/titan/0.6/libtitan.a`.
4. The LuaRocks package is versioned for the semantic release and its filename,
   manifest expectations, cache inputs, and source-rock tests advance together.
5. No compatibility aliases, old-path cleanup, migrations, symlinks, or
   parallel legacy namespaces are introduced.

## Implementation

1. Define and validate the reset versions in the Makefile, Lua compiler driver,
   and C runtime header. Replace the overloaded legacy names with explicit ABI
   and release/library-version names.
2. Route generated ABI marker functions, static metadata validation, runtime
   mismatch diagnostics, and compiler-side provider validation through
   `TITAN_ABI_VERSION`.
3. Route install/search/share paths, Lua C-path configuration, generated legacy-
   layout absence checks, installed `libtitan.a`, and `TITAN_PATH_0_6` through
   the derived major/minor library version.
4. Rename the LuaRocks specification for release `0.6.0`, update its package
   version/revision, and update all build, CI, source-pack, and manifest users.
5. Update installer, smoke, snapshot, async-helper, and CI wiring to distinguish
   ABI cache inputs from library-version paths.
6. Rewrite ABI and packaging regressions around the reset model. Use a synthetic
   nonmatching integer ABI for rejection tests; remove preserved-installation
   tests that are no longer part of the contract.
7. Rewrite README, manuals, contributor guidance, code comments, and retained
   design documents so they explain the current invariant without historical
   Titan numbering.

## Verification

1. Static audit for overloaded or historical Titan version constants, paths,
   environment variables, rock names, and documentation prose.
2. Focused Busted gates for ABI/driver metadata, static metadata, installer,
   rockspec, native dependency build, and compiled-module loading.
3. Source-rock pack/unpack and installed-prefix publication checks through the
   existing packaging specs.
4. Canonical isolated-prefix `make test` with ambient Titan path/build-policy
   variables cleared.
5. Review the final diff, commit, push the feature branch, open the PR, and wait
   for the regular Linux/Codecov graph. Do not dispatch the macOS workflow
   without express maintainer authorization.
