# Titan module self-registration in `package.preload`

## Feasibility and delivery scope

The change is feasible as a small extension to every generated Titan module,
without changing the standalone application bootstrap. Lua exposes
`package.preload` as the registry table named by `LUA_PRELOAD_TABLE`. Each
generated module already knows its logical name and `luaopen_<mangled>` entry,
and its `_init` function is invoked by the existing Titan import recursion.
After a module finishes initialization successfully, it can publish that entry
directly through ordinary Lua stack APIs.

Work is stacked on PR #119. The feature branch
`codex/standalone-module-preload` starts at its exact head
`9b1a24be678e8e23ade30a7b218debccaf91557a`; the new PR must target
`codex/issue-113-libuv-work-queue` so it contains only this feature.

Keep `TITAN_VERSION=0.6.0` and `TITAN_ABI_VERSION=2` unchanged. This adds an
ordinary Lua-loader registration side effect after successful initialization;
it does not change module userdata, metadata, symbols, or the native ABI.

## Contract

- Every generated Titan module registers its own `luaopen_*` function under
  its logical name in the registry's `LUA_PRELOAD_TABLE` after its `_init`
  completes successfully.
- `package.preload` aliases that registry table. If the package library has not
  been opened yet, `luaL_getsubtable` creates the table and `luaopen_package`
  later reuses it.
- Registration does not initialize a module. The existing caller remains
  responsible for initialization: in a standalone, requiring the main module
  performs the normal complete static import recursion before `main` runs.
- Because registration follows `_init`, the complete initialized closure is
  published automatically, including producer-private dependencies selected
  from a static archive. An unused archive sibling or unrelated uninitialized
  root is not published.
- A later ordinary Lua `require` or `titan.lua.require` invokes the registered
  opener. `_init` finds and returns the canonical module userdata already in
  the registry, and Lua applies its ordinary `package.loaded` cache policy.
- Publish only after successful initialization. In particular, a reentrant
  observation of a partially initialized module in an import cycle must not
  expose its loader early.
- Use only ordinary Lua APIs and stack values, with no native ABI change.

## Production changes

1. `titan-compiler/coder/module.lua`
   - Forward-declare the module's `luaopen_*` entry before `_init`.
   - Generate one translation-unit-local helper that obtains
     `LUA_PRELOAD_TABLE`, stores the module's opener under its logical name, and
     restores the Lua stack.
   - Call the helper at the successful completion point of a newly initialized
     module and after successful setup when adopting an already canonical
     module from another physical provider. Do not call it on the reentrant
     `_initialized` fast path.
2. `titan-compiler/coder/generate.lua`
   - Supply the logical-name, opener, and private-helper substitutions to the
     module initializer template.
3. Leave `titan-compiler/driver.lua`, `titanc`, static metadata, and the
   standalone bootstrap protocol unchanged. The bootstrap continues to preload
   only the main opener needed to begin its ordinary initialization recursion.

## Regression plan

- Extend `spec/coder/multi_module_grouping_spec.lua` with a standalone whose
  main module imports a transitive source closure. Before any dynamic require
  in `main`, prove each imported module is initialized exactly once, absent
  from `package.loaded`, and present in `package.preload`; then require it,
  exercise public behavior, and prove repeat identity without reinitialization.
- Extend `spec/coder/multi_module_libraries_spec.lua` with an archive-backed
  selected module, its producer-private dependency, and an unused sibling.
  Remove the provider DSO and shims before execution, then prove the selected
  module and private dependency are preloaded and dynamically requireable while
  the unused sibling is not published.
- Inspect generated module C for registry-backed preload publication and run
  existing native embedding coverage to ensure initialization remains valid
  before the package library is opened.

## Documentation

- Update the language manual to describe initialized Titan modules becoming
  ordinary preload candidates, the distinction from `package.loaded`, and the
  unchanged standalone bootstrap initialization timing.
- Update the implementation manual with the registry alias, generated `_init`
  publication point, cycle-safe completion boundary, and canonical-userdata
  behavior on later require.

## Validation and publication

1. Run `luac -p` over changed Lua compiler/spec files and `git diff --check`.
2. Install the current compiler into an isolated absolute prefix, then run the
   focused source/static standalone regressions.
3. Run the complete owning coder specs and all four compiler/language shards.
4. Run the canonical mixed `make -j2 test` from a clean policy environment.
5. Perform independent implementation, test-coverage, and documentation
   reviews; address every material finding and rerun affected gates.
6. Commit, push, open the stacked PR against
   `codex/issue-113-libuv-work-queue`, and monitor Linux and both Codecov checks
   to green.
7. The cold macOS workflow remains a required pre-merge gate, but do not
   dispatch it without the maintainer's express authorization.

## Progress log

- 2026-08-28: verified PR #119's head and base, created the stacked feature
  branch, and traced the standalone bootstrap, generated module initialization,
  and Lua require path.
- 2026-08-28: implemented generated-module self-registration after successful
  `_init`, with the standalone entrypoint and static metadata unchanged.
- 2026-08-28: added source-closure, private-static-dependency, unused-sibling,
  DSO, generated-C, and pre-package registry regressions; updated both manuals.
- 2026-08-28: independent implementation, test, and documentation reviews found
  no material defects after revision. The isolated-prefix `make -j2 test` gate
  passed 127 runtime/packaging specs, all four compiler shards, and 205 native
  Titan tests.
