# Runtime file-renaming audit (`feature/ffi-wrapup`)

Audited at `f274b9d` on `feature/ffi-wrapup`. This is an implementation checklist for the approved physical cleanup:

| Old | New / final state |
| --- | --- |
| `titan-runtime/titan_coro.c` | `titan-runtime/minicoro.c` |
| `titan-runtime/titan_coro.o` | `titan-runtime/minicoro.o` |
| `titan-runtime/titanlib.c` | `titan-runtime/ltitanlib.c` |
| `titan-runtime/titanlib.o` | `titan-runtime/ltitanlib.o` |
| `titan-runtime/titan_longjmp.h` | contents live directly in `titan-runtime/titan.h`; old source and installed header are absent |

The intended resulting contracts are:

* runtime SDK `libtitan.a` has exactly, in order, `titan.o`, `minicoro.o`;
* the private bootstrap is linked only from `ltitanlib.o`;
* the standard provider `-X` payload begins with `ltitanlib.o`, then private LPegLabel, selected libuv, private llhttp, and selected OpenSSL payload;
* the Titan-owned non-Lua installed headers are top-level `minicoro.h`, top-level `titan.h`, and namespaced `titan/ffi.h` (plus separately governed bundled-libuv headers); there is no installed `titan_longjmp.h`.

## 1. Source moves and invariants

- [ ] Use real Git moves for `titan_coro.c -> minicoro.c` and `titanlib.c -> ltitanlib.c`; delete `titan_longjmp.h` only after moving its complete live block into `titan.h`.
- [ ] In `minicoro.c`, preserve the one-and-only `MINICORO_IMPL` translation unit, `MCO_NO_DEBUG`, `MCO_USE_VMEM_ALLOCATOR`, the fixed `MCO_TAG_COMPARATOR`, and the declaration-before-`#include "minicoro.h"` ordering. Multiple implementation units would duplicate all `mco_*` definitions.
- [ ] Preserve the comparator's raw semantics: `luaV_equalobj(NULL, ...)`, no Lua state, no metamethod. `titan_coro_tag_equal` is translation-unit-local, so renaming it to `minicoro_tag_equal` would be ABI-neutral, but it is **not required by the approved file/object rename**. If it is renamed, also update the live examples in `doc/async-with-coroutines.md` and `doc/implementation/coroutines.md`.
- [ ] Do not mechanically rename unrelated `titan_coro_*` names. In particular, generated `titan_coroutine_*`/`luaopen_titan_coroutine`, retired-symbol prose for `titan_coro_entry` and `titan_coro_{root,clear}_transfer`, `TITAN_CORO_OWNER_USERVALUES`, and `spec/fixtures/stdlib/native/coroutine_transfer_fault.h`'s `titan_coro_test_*` fixture functions are logical/symbol/test names, not file references.
- [ ] In `ltitanlib.c`, keep the logical Lua module and native API unchanged: `luaopen_titan`, the `titanlib` registration array (private and harmless if retained), `TITAN_*` registry keys, `backtrace`/`pin`/`clear`, `_loadlib`, and `_loadlibglobal`. The filename/object rename must not become a Lua module rename.
- [ ] Move the longjmp block into `titan.h` under `TITAN_H` rather than nesting the deleted header's `TITAN_LONGJMP_H` guard. Add `<setjmp.h>` to `titan.h`; reuse its existing `llimits.h` include for `TStatus`; retain the exact Lua-5.5.1 provenance, byte-compatible `lua_longjmp` layout, and POSIX `_setjmp` versus ISO `setjmp` selection for `TITAN_SETJMP`.
- [ ] Keep the vendored structure definition byte-for-byte/field-for-field compatible with the linked Lua (`previous`, `jmp_buf b`, `volatile TStatus status`). This is a location-only move; do not replace it with a public Lua API, a thunk, or a different exception mechanism.

## 2. Makefile, stamps, installation, and cleanup

### Names and rules

- [ ] At `Makefile:294-301`, change the physical object definitions to `MINICORO_O := titan-runtime/minicoro.o` and `LTITANLIB_O := titan-runtime/ltitanlib.o`, and make `TITAN_RUNTIME_OBJECTS := $(RUNTIME_O) $(MINICORO_O)`. Renaming the Make identifiers as well as their values avoids leaving `CORO_O`/`TITANLIB_O` as misleading contracts.
- [ ] Change `STDLIB_EXTRA_OBJECTS` to start with `$(LTITANLIB_O)`.
- [ ] Rename `TITANLIB_BUILD_CONFIG` coherently to `LTITANLIB_BUILD_CONFIG`, with a stamp such as `titan-runtime/.titan-ltitanlib-build-config`; update its FORCE rule, object prerequisite, and `clean` reference.
- [ ] Update the shared-runtime comment and object rule at `Makefile:1671,1729-1734`: target `$(MINICORO_O)`, prerequisite/compile input `titan-runtime/minicoro.c`, output `minicoro.o`.
- [ ] Keep `titan-runtime/titan/ffi.h` in the minicoro rule unless its current indirect freshness role is replaced explicitly. `minicoro.c` does not include it, but the feature branch deliberately uses the runtime object/native prerequisite path to make a warm stdlib rebuild notice edits to the generated callbacks' bridge header. Blindly “pruning unused includes” here can leave a warm `titan.so`/`titan.a` stale.
- [ ] Remove `titan-runtime/titan_longjmp.h` from `TITAN_SDK_ROOT_HEADERS` and from the `titan.o` prerequisite list. `titan.h` remains the dependency and now owns the moved contents.
- [ ] Update the support-object rule to `$(LTITANLIB_O): titan-runtime/ltitanlib.c $(LTITANLIB_BUILD_CONFIG)` and the bootstrap dependency to `$(TITAN_BOOTSTRAP_SO): $(LTITANLIB_O)`. `$<` must still resolve to the C source for compilation and to the object for bootstrap linking.
- [ ] Update Make comments at current lines 1699, 1855, and 2061 from the old physical names.

### Warm-build invalidation

- [ ] Preserve `RUNTIME_ARCHIVE_CONFIG` as the exact-member stamp. Its generated `MEMBERS=` value must become `titan.o minicoro.o`; because the rule is FORCE/content-stable, an old warm stamp changes and forces `libtitan.a` to be removed/rebuilt instead of letting `ar` retain `titan_coro.o`.
- [ ] Preserve `STDLIB_CONFIG_STAMP`'s `STDLIB_EXTRA_OBJECTS=` recording. The path change to `ltitanlib.o` must invalidate `.titan-stdlib-complete` and rebuild both standard-provider forms on a same-ABI warm tree.
- [ ] The new `ltitanlib.o` must make the existing private bootstrap stale and relink it. Do not add `libtitan.a` or other runtime inputs to that bootstrap; it remains a one-object support image.
- [ ] If the support build-config stamp is renamed, make `make clean` remove the retired exact `titan-runtime/.titan-titanlib-build-config` as well as the new stamp. This is a bounded ignored build artifact, not cross-ABI migration.
- [ ] No extra object cleanup rule is required for correctness: current `rm -f titan-runtime/*.o` already removes both old and new object spellings. A normal warm build may leave ignored old `.o` files on disk, but exact variable lists and archive validation keep them out of artifacts. Do not add broad cleanup outside `titan-runtime/`.

### Installed header removal

- [ ] Merely deleting the header from `TITAN_SDK_ROOT_HEADERS` is insufficient: `install-titan-sdk` copies into an existing prefix and never prunes it. Add an exact `rm -f "$rocks_tree/include/titan_longjmp.h"` in that target so cached/warm prefixes satisfy the approved installed inventory. Do not purge other ABI directories or broad header globs.
- [ ] Keep `titan.h` and `minicoro.h` installation modes/paths unchanged. The old header is direct SDK state outside the rock manifest, so LuaRocks removal/manifest logic will not remove it for us.

## 3. Compiler driver

- [ ] In `titan-compiler/driver.lua:RUNTIME_ARCHIVE_INPUTS` (current lines 2272-2279), replace `titan_coro.c` with `minicoro.c` and remove `titan_longjmp.h`; `titan.h` now covers its mtime. Retain `minicoro.h` and `titan/ffi.h` for the same runtime/warm-build freshness contract.
- [ ] Change `RUNTIME_ARCHIVE_MEMBERS` to exact ordered `{ "titan.o", "minicoro.o" }`.
- [ ] Do not change runtime link ordering, `libtitan.a` paths, archive-index filtering, or installed-mode behavior. The rename changes archive member spelling, not native symbols.

## 4. Tests and fixtures requiring literal updates

- [ ] `spec/driver_spec.lua:154-167`: make `titan.o\nminicoro.o\n` (with supported BSD index variants) the valid manifest; update extra/stale/reversed negative fixtures, and preferably add the old `titan.o\ntitan_coro.o\n` pair as an explicit rejected legacy spelling.
- [ ] `spec/libuv_build_spec.lua`:
  - [ ] update Make-contract expectations from `$(CORO_O)` to `$(MINICORO_O)` (current 796, 1527) and `$(TITANLIB_O)` to `$(LTITANLIB_O)` (868, 1518, 2207);
  - [ ] update the Darwin bootstrap dry-run expectation (1546-1549) to `titan-runtime/ltitanlib.o`;
  - [ ] update the fake archive object paths and fake BSD `ar t` output (1560-1569) to `minicoro.o`;
  - [ ] update every bundled/system/Darwin/OpenSSL/rebuild `-X titan-runtime/titanlib.o ...` assertion (1745, 1775, 1796, 1830, 1885) to `ltitanlib.o`;
  - [ ] optionally lock the source cleanup by asserting `minicoro.c`/`ltitanlib.c` exist and the two old C paths plus `titan_longjmp.h` do not.
- [ ] `spec/lpeglabel_build_spec.lua:508-511`: update the guard against accidentally adding LPegLabel to `TITAN_RUNTIME_OBJECTS` to use `$(MINICORO_O)`.
- [ ] `spec/rockspec_spec.lua`:
  - [ ] installed-header inventory (221-225): remove `titan_longjmp.h` from the positive list and assert that exact installed path is absent;
  - [ ] installed runtime archive expectation (346-352): `{ "titan.o", "minicoro.o" }`;
  - [ ] source-rock inventory can explicitly require `titan-runtime/minicoro.c`, `titan-runtime/ltitanlib.c`, and `titan-runtime/titan.h`, and reject the old two C paths/header, so Git/source packaging is covered rather than assumed.
- [ ] `spec/coder/multi_module_libraries_spec.lua:2360`: change the explicit support `-X` path to `titan-runtime/ltitanlib.o`.
- [ ] `spec/support/async_stdlib.lua:416-418`: change the prepared support path and diagnostic to `ltitanlib.o`.
- [ ] Existing `spec/coder/error_handling_spec.lua` compile/runtime cases remain the semantic regression coverage for the folded header; no generated C include changes are expected because `cpreamble.lua` already includes only `titan.h`.
- [ ] Existing `spec/minicoro_spec.lua` includes `minicoro.h`, not the implementation filename, and needs no rename.

## 5. Live documentation and CI references

Update physical names in these maintained descriptions (line numbers refer to `f274b9d`):

- [ ] `.agents/plans/ffi-wrapup.md:297,324-329` — this is the active feature plan/final-state statement: `minicoro.c`, `minicoro.o`, no separate longjmp header, `ltitanlib.o`.
- [ ] `.github/workflows/ci.yml:488` — comment only: `ltitanlib.c`. No CI command/cache key names either object.
- [ ] `README.md:103,105,339` — exact runtime members, reduced top-level header list, standard payload.
- [ ] `AGENTS.md:182-203,597-603,1267-1275` — use the new names and the folded header inventory. These paragraphs are also stale relative to this branch: do not preserve `titan_uv.o`, `titan/{coro,uv}.h`, or the deleted HTTP adapter while touching them; the true branch state is two runtime members and only `titan/ffi.h` namespaced.
- [ ] `doc/async-with-coroutines.md:211,637-642` — `minicoro.c` and extracted `minicoro.o` (plus comparator snippet only if the private comparator is renamed).
- [ ] `doc/implementation/coroutines.md:9,282-298,313-316` — implementation path/name, and optional comparator identifier as above. Retired exported helper names at line 298 stay unchanged.
- [ ] `doc/implementation/driver.md:100-101,372-375,688,725,733,737,894-910,1031-1036,1093-1097` — source/object/payload names, section title, exact header inventory, and loader table source column.
- [ ] `doc/implementation/error-handling.md:216-219` — say the Lua layout and selector are vendored directly in `titan-runtime/titan.h`.
- [ ] `doc/implementation/folder-modules.md:325` — `-X titan-runtime/ltitanlib.o` example.
- [ ] `doc/implementation/foreign-functions.md:435-438,462-468` — `minicoro.c`, exact archive pair, folded header list, `ltitanlib.o` payload.
- [ ] `doc/implementation/index.md:153` — rewrite the runtime-directory inventory in one pass: `minicoro.c`/`minicoro.o`, `ltitanlib.c`/`ltitanlib.o`, and no `titan_longjmp.h`.
- [ ] `doc/implementation/lpeglabel-embedding.md:414` — payload member `ltitanlib.o`.
- [ ] `doc/implementation/lua-5.5.1-update.md:158-164` — update the audited vendored-block location to `titan.h`; the historical 5.5.1 conclusion remains unchanged.
- [ ] `doc/implementation/lua-interop-internals.md:640-641,794` — private-key source annotations and support source/object path.
- [ ] `doc/implementation/multi-module-libraries.md:254,282,289,310` — support source/object and bootstrap input.
- [ ] `doc/implementation/static-compiled-modules.md:59` — `ltitanlib.o` native input.
- [ ] `doc/implementation/string-library.md:90` — metadata-free payload begins with `ltitanlib.o`.
- [ ] `doc/language/modules.md:476-482` — exact runtime members and `ltitanlib.c` support source.
- [ ] `doc/lua-5.5-migration.md:73` — historical audit's current source filename becomes `ltitanlib.c`.

### Historical `.agents/plans` references: classify, do not blind-replace

A repository-wide grep will still find point-in-time research that accurately describes older layouts. Only `.agents/plans/ffi-wrapup.md` above declares this feature's maintained final state. The following are archival/research narratives and should normally remain historical rather than be mechanically rewritten:

* `error-handling-implementation-plan.md`, `error-handling-traceback-research.md`;
* `ffi-improvements.md`, `ffi-wrapup-doc-final-review.md`, `ffi-wrapup-docs-tests-research.md`, `ffi-wrapup-shims-research.md`;
* `libuv-async-io-standard-library.md`, `multiple-modules-single-so.md`, `peg-and-string-standard-library.md`, `static-compiled-modules.md`, `stdlib-boundary-test-review.md`, `type-relations-soundness.md`.

Those files contain old-state claims, proposed names, or retired symbol names; a global `titan_coro -> minicoro`/`titanlib -> ltitanlib` replacement would make some of their historical reasoning false. If project policy instead requires zero stale physical path text, review each occurrence manually and distinguish old-state prose from current-final-state prose.

## 6. Semantic/non-changes to protect

- [ ] No ABI bump: source filenames, object member names, and an equivalent header fold do not change serialized types, generated native signatures, Lua 5.5.1 layout, or exported symbols. ABI remains 0.23.
- [ ] No installer predecessor/migration expansion: the ordinary current-ABI stdlib stamp/publisher rebuild is enough. The only exact installed-state deletion approved here is the unversioned retired `include/titan_longjmp.h`.
- [ ] `minicoro.o` remains in `libtitan.a`; it is **not** added as an `-X` member of `titan.a`. Static consumers extract it from the separately linked runtime archive when `titan.coroutine` references `mco_*`.
- [ ] `ltitanlib.o` remains outside `libtitan.a`, metadata-free, first in the standard `-X` payload, and the sole private-bootstrap input. Do not confuse `ltitanlib` with the `libtitan.a` runtime archive.
- [ ] Renaming source files changes DWARF/source-path text and archive leaf names only. Runtime frames under `titan-runtime/` remain filtered by the existing path rule; native APIs remain the same.
- [ ] Do not rename logical module `titan`, `require "titan"`, `luaopen_titan`, Titan coroutine mangling, registry keys, or public/minicoro `mco_*` symbols.

## 7. Negative findings (no edit expected)

- [ ] `.gitignore` already covers `*.o`, `/titan-runtime/.titan-*-build-config`, and the bootstrap directory; the new object/stamp spellings need no new ignore rule.
- [ ] `titan-dev-1.rockspec` delegates the build to Make and packages the Git source tree; it has no literal runtime C/object/header list to rename.
- [ ] `scripts/stdlib_installer.lua`, `spec/support/ci_stdlib_snapshot.sh`, sanitizer mapping scripts, and production smoke scripts refer to the runtime archive/provider as wholes, not these member names; no mechanical update is needed.
- [ ] `titan-compiler/cpreamble.lua` already includes `titan.h` only, so folding the block requires no generated-preamble change.

## 8. Validation checklist

- [ ] On a warm tree containing the current old objects/stamps, run the new runtime target without first cleaning. Confirm `ar t titan-runtime/libtitan.a` is exactly:

  ```text
  titan.o
  minicoro.o
  ```

  and `.titan-runtime-archive-build-config` records those members.
- [ ] Build the private bootstrap and both bundled/system standard-provider configurations; inspect dry-run/link commands for only `ltitanlib.o`, and `ar t titan.a` for `ltitanlib.o` (not `titanlib.o`). Confirm `minicoro.o` is not flattened there.
- [ ] Install into a pre-existing test prefix that already contains `include/titan_longjmp.h`; verify the path is gone, `include/titan.h` is present, and a generated catch/finally module compiles against the installed SDK.
- [ ] Run the focused specs after rebuilding the installed compiler snapshot: `spec/driver_spec.lua`, `spec/libuv_build_spec.lua`, `spec/lpeglabel_build_spec.lua`, `spec/rockspec_spec.lua`, `spec/coder/multi_module_libraries_spec.lua`, and the error-handling/minicoro specs.
- [ ] Run `make clean` and verify both old/new `.o` spellings and both old/new support build-config stamps are absent while tracked runtime sources remain.
- [ ] Run a scoped final grep over maintained code/tests/docs for exact old **physical** spellings, excluding intentionally historical `.agents/plans` and unrelated retired/test symbol names.
- [ ] Complete the repository's ordinary Linux suite and dispatch-only macOS pre-merge gate; archive member indexing and bundle linking are platform-sensitive parts of this cleanup.
