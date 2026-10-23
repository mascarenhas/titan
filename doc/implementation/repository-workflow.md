# Repository development workflow

This chapter covers Linux and macOS setup, command selection, and artifact
ownership. Use [Windows builds](windows-build.md) for native CLANG64/UCRT
commands, [build responsibilities](build-script-audit.md) for recipe ownership,
and [continuous integration](continuous-integration.md) for hosted and VM gates.
Compiler flags, provider protocols, installation layout, and environment
variables are specified in the [driver chapter](driver.md).

## Prepare an isolated installation

The compiler and generated code require the pinned Lua 5.5.1 fork and matching
internal headers/archive. Initialize its submodule, choose an absolute prefix,
and put that prefix's tools first on `PATH`:

```sh
git submodule update --init --recursive
export PREFIX="/tmp/titan-$USER-test"
export PATH="$PREFIX/bin:$PATH"
export TITAN_BUILD_PROFILE=validation
make lua
make luarocks
luarocks make titan-0.6.0-1.rockspec
luarocks test --prepare
```

Use a distinct prefix and source copy for each concurrent repository build. A
worktree isolates checkout artifacts, including authored runtime/native
dependency builds; an isolated prefix also separates installed compiler
snapshots, native SDKs, and providers. Standalone Titan compilations can share
sources with separate `--output` directories, as described below. Installed
SDKs are consumer inputs, not scratch directories. Prefer `/tmp` prefixes for
throwaway verification over checkout-local `.lua` or `lua_modules` trees.

This example prepares a validation SDK. Use a separate prefix and select
`production` for ordinary release/install work rather than changing the profile
of this installation in place.

Lua and LuaRocks preparation, `LUA_PLATFORM` and the Readline requirement are
described in [build and installation
responsibilities](build-script-audit.md#lua-and-native-dependencies). Native
dependency preparation needs CMake, Perl, tar, curl or wget, and sha256sum or
shasum. `CC`, `AR`, and `RANLIB` may be command strings; pass the same selected
tools through Make, LuaRocks, installation checks, and consumer builds.
`clang-format` is needed only for `titanc --pretty-print`.

`PREFIX` owns Lua and LuaRocks; `ROCKS_TREE` owns the Titan rock, SDK, and
standard provider and defaults to `PREFIX`. The supported developer layout sets
them equal. Unix supports separate destinations; Windows requires the same
physical prefix.

A warm `make lua` or `make luarocks` checks only for its installed program, not
source, tool or flag fingerprints. Clean upstream objects and remove or replace
that program when intentionally changing native inputs. Build recipes never
patch the fork's source. Its executable-relative Lua search paths do not
relocate all LuaRocks configuration or third-party launchers; replace an old
project-tree installation rather than trying to migrate it. See
[Lua installation](driver.md#lua-installation-and-executable-relative-search-paths).

## Choose the matching profile and command

Unset ordinary build/install invocations select `production`. The repository
test goals (`Makefile` `TITAN_TEST_GOALS`, the shared test scripts, and the
Busted/CI wrappers) select `validation`, and without an explicit `PREFIX` a
validation invocation uses the checkout's `.lua-validation` prefix instead of
the prefix discovered on `PATH`. Keep production and validation prefixes
separate rather than republishing another profile into an active SDK. The
SDK records its profile in `etc/titan/build-profile`; inspect it and the
effective compiler argv when recording evidence. Per-component optimization
levels, including the sanitizer domains, are specified in [build
profiles](../language/build-profiles.md); test-harness flag overrides are in the
[test-runner profile contract](test-runner.md#validation-profile-and-isolated-sdks).

Distinct `--output` roots can separate generated Titan objects, but
repository Make builds default to one `out/` tree, and authored runtime and
native dependency builds share their checkout locations. Serialize builds that
share those inputs or use private source copies. Within one checkout,
libbacktrace and libuv rebuild once when the profile, compiler, or their flags
change ([configuration
stamps](build-script-audit.md#native-dependency-configuration-stamps)); the
other native trees and the standard library still need the clean steps below.

Run full validation without ambient `ROCKS_TREE`, `TITAN_ROCKS_ROOT`,
`TITAN_EXTRA_CPPFLAGS`, or `TITAN_NO_LINE_DIRECTIVES`. These alter SDK/provider
selection, fixture preprocessing, or traceback attribution. Make unsets
`LUA_PATH`, `LUA_CPATH`, and their Lua 5.5 variants for its test and compiler
invocations; clear them for manual prefix-tool invocations too, especially
after a shell used `luarocks init`. Native test builds use `TITAN_EXTRA_*FLAGS`
when set and otherwise `TITAN_TEST_EXTRA_*FLAGS` (`Makefile`
`TITAN_TEST_CFLAGS`); other explicit build-policy inputs are caller-owned.

Lua's internal assertions are a diagnostic configuration. In a separate source
copy and prefix, add `-DLUAI_ASSERT` to `LUA_MYCFLAGS` (keeping the profile's
`-fPIC` and host flags, for example `-fPIC -O2 -fno-lto -DLUAI_ASSERT` under
validation) and, to check Titan's own uses of Lua internals too, build the
runtime, standard library, and tests with `TITAN_EXTRA_CPPFLAGS=-DLUAI_ASSERT`.
Lua's `api_check` then also becomes an assertion, so it reports any public Lua
C API call that pushes past its frame's reserved stack top; generated and
runtime code that writes the stack through Lua internals is not checked.

| Command, from the repository root | Purpose |
| --- | --- |
| `make test` | Prepare the selected SDK, reinstall the current compiler/provider with `luarocks make --force`, and run the complete mixed suite through `luarocks test`. |
| `TITAN_JOBS=4 make -j4 test` | Four-way native/generated-C preparation variant. |
| `luarocks test` | Run against an already current install; its active `bin` on `PATH` is sufficient. It does not build the rock. |
| `make rock-test` | Both test domains. In validation with no `PREFIX/bin/titanc`, it runs `make test` instead. |
| `make busted-test BUSTED_FILTER='for loop'` | Busted only. |
| `make stdlib-test` | Retained runtime/packaging Busted specs, then the native aggregate; no compiler specs and no coverage. |
| `make titan-stdlib-test` | Build and run the aggregate native suite. |
| `make titan-stdlib-test-build` | Build all native roots once. |
| `make titan-stdlib-test-run TITAN_FILTER='^ssl[.]tests[.]'` | Filter a fresh execution of the existing aggregate; never filter compilation. |
| `TMPDIR=/tmp/run-a make titan-stdlib-test-run TITAN_FILTER='^uv[.]' TITAN_TEST_RUN_LOG=/tmp/run-a/stdout.log` | Unix: one of several concurrent filtered executions of the same built aggregate; give each its own log and `TMPDIR` ([concurrent runs](test-runner.md#concurrent-filtered-runs)). |
| `make rock-test BUSTED_FILTER='parser' TITAN_FILTER='^http[.]tests[.]'` | Independently filter both domains. Neither filter skips the other domain. |
| `make titan-native-coverage` | Build and run the source-linked native coverage aggregate; see [native coverage](native-coverage.md#repository-integration-and-verification). |
| `make stdlib` / `make install-stdlib` | Incremental standard-provider build / build then copy, using the installed compiler/SDK by default. |
| `make clean-stdlib` | Clear standard-provider outputs before changing tools, flags, profile, or OpenSSL mode. |
| `make clean` / `make distclean` | Remove owned generated artifacts / also remove downloaded native dependency trees. |

Leaf build/run targets require a prepared matching SDK. Default Busted,
`make busted-test`, `luarocks test`, and installed `titanc` use the installed
compiler snapshot. Reinstall after compiler, runtime, or standard-library
changes. `make test` owns this refresh; `luarocks test` alone does not.
The Busted partitioning behind `rock-test` and `luarocks test` is described in
[test runner](test-runner.md#busted-partitions).

`titanc` accepts dotted module names, not file paths. Use its
[CLI reference](driver.md#the-titanc-command-line) for provider/standalone
selection, `--tree`, `--output`, incremental object reuse, `-c`, and test mode.
Source-rock `all` uses the in-tree compiler and private bootstrap; ordinary
`stdlib` uses the installed compiler unless `STDLIB_USE_INSTALLED_RUNTIME=0`.
Packaging, binary rocks, and uninstall are documented in [build and
installation responsibilities](build-script-audit.md#installation-and-publication).

## Run checkout compiler Lua with Busted

For focused compiler Lua edits, use the explicit checkout profile:

```sh
TITAN_ROCKS_ROOT="$PREFIX" TITAN_PROBE_CACHE_DISABLE=1 \
  busted --run=checkout spec/parser_spec.lua
TITAN_ROCKS_ROOT="$PREFIX" TITAN_PROBE_CACHE_DISABLE=1 \
  busted --run=checkout spec/coder/coder_spec.lua --filter='for loop'
```

The `.busted` `checkout` profile prepends `./?.lua;./?/init.lua` after the
LuaRocks launcher has initialized its paths, so edited checkout compiler
modules load without reinstalling them; an ambient checkout-first `LUA_PATH`
alone does not have that precedence. The C module path is unchanged. The
profile's helper, `spec/support/checkout_busted.lua`, rejects a missing
`TITAN_ROCKS_ROOT`, creates one resolver context to initialize the driver
layout, calls `driver.configure_foreign_c` so direct checker FFI imports use the
installed SDK headers, and closes the context. It changes no compiler loader
or source-identity mechanism. `TITAN_ROCKS_ROOT` separately preserves the
installed driver layout, headers and runtime libraries; scope it to this
command.

The profile refreshes neither installed tools, the SDK/provider, nor a compiled
native aggregate. The real-launcher regression in `spec/libuv_build_spec.lua`
compares a deliberate checkout compiler edit with the unchanged installed
module: default Busted stays installed even with `.busted` present, active
native dependency/SDK paths match, an installed `lua.h` import works through the
direct checker without checkout Lua headers, and a missing root option or a
broken local module fails rather than falling back to the install.

## Route generated output explicitly

`titanc --output DIRECTORY` keeps generated C, objects, headers, providers,
loaders, and programs below that directory while preserving their source-root
hierarchy. Use one output directory consistently for incremental object recipes
and the final link. `--tree` still selects sources; `--output` changes neither
source identity nor provider/Lua search paths. Omitting it preserves the legacy
source-adjacent generation behavior. See
[output-directory routing](output-directory.md) for the exact mapping.

Repository Make builds default to `TITAN_OUTPUT_DIR=out`: the standard-provider
pair and loaders stage there, native tests use `out/tests`, and native coverage
uses `out/coverage` with reports in `out/coverage/report`. An output root can
separate generated Titan configurations; flags and tools still require explicit
invalidation. Authored runtime C objects, native dependency archives, and SDK
probe caches retain their own locations and ownership, so changing only the
output directory does not isolate all repository build inputs.

## Preserve fixture and shared-output ownership

All spec paths are relative to the repository-root CWD. Shared compile/check/run
helpers live in `spec/support/helpers.lua`; require them as
`spec.support.helpers`. Set `helpers.verbose = true` to print native commands
and retain generated C. Required modules load `luassert` explicitly because
they do not inherit Busted's assertion global. Helpers touching checker/coder
state reset `types.registry` and, for imports, `driver.imported` first.

Compiler fixtures remove only their exact artifacts, including the paired
`.a` from a no-main compile. Treat `titan-runtime/libtitan.a`, the standard
stage's `out/titan.so`/`out/titan.a` and shims, canonical installed providers,
and native dependency archives as shared Make-owned state. Helpers must not
invalidate them to force a rebuild. `make clean` removes the selected
`TITAN_OUTPUT_DIR` as an owned output tree. The bounded cleanup rules for
`out/tests`, legacy same-stem generated C, synthetic test suffixes, and
interrupted root fixtures are in the
[test-runner chapter](test-runner.md#platform-portability-and-complete-execution).
Never replace these with broad archive, Lua, or `spec/**/*.c` deletion globs.

Parser/checker assertions use `restrict` plus `assert_is_subset` so unrelated
AST decorations do not break expectations. Checked ASTs are self-referential;
unlimited luassert `TableFormatLevel` can hang failure printing. Change and
restore printing depth within setup/teardown rather than leaking collection-time
global settings. DSO-only regressions must exclude both source and archive
fallbacks and assert dynamic selection; preprocessor recursion regressions keep
their instruction-count bound. Regression placement is indexed in
[test layers](test-runner.md#regression-placement).
