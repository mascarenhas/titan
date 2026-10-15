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

Use a distinct prefix and source copy for each concurrent build. A worktree
isolates checkout artifacts; an isolated prefix also separates installed
compiler snapshots, native SDKs, and providers. Installed SDKs are consumer
inputs, not scratch directories. Prefer `/tmp` prefixes for throwaway
verification over checkout-local `.lua` or `lua_modules` trees.

This example prepares a validation SDK. Use a separate prefix and select
`production` for ordinary release/install work rather than changing the profile
of this installation in place.

Linux Lua defaults to `linux-readline`, macOS to `macosx`; supply system
Readline development files or select `LUA_PLATFORM` explicitly. Native
dependency preparation needs CMake, Perl, tar, curl or wget, and sha256sum or
shasum. `CC`, `AR`, and `RANLIB` may be command strings; pass the same selected
tools through Make, LuaRocks, installation checks, and consumer builds.
`clang-format` is needed only for `titanc --pretty-print`.

`PREFIX` owns Lua and LuaRocks; `ROCKS_TREE` owns the Titan rock, SDK, and
standard provider. The supported developer layout sets them equal. Unix
supports separate destinations; Windows requires the same physical prefix.
Make discovers a Titan Lua prefix from `PATH`, with an explicit `PREFIX`
taking precedence and `/usr/local` as fallback.

Preparation checks installed programs, not source/tool/flag fingerprints.
A warm `make lua` or `make luarocks` skips work when its installed program
exists. Clean upstream objects and remove or replace that program when
intentionally changing native inputs. The fork's source is never patched by
build recipes. Its executable-relative Lua search paths do not relocate all
LuaRocks configuration or third-party launchers; replace an old project-tree
installation rather than trying to migrate it. See
[Lua installation](driver.md#lua-installation-and-executable-relative-search-paths).

## Choose the matching profile and command

Unset ordinary build/install invocations select `production`; repository test
entry points select `validation`. Keep their prefixes separate. Validation
uses O0/no LTO for Titan and most native dependencies, while Lua, LPegLabel,
and Lua filesystem retain O2/no LTO. Sanitizer host/parser components use
fully instrumented O1/no LTO. Inspect `etc/titan/build-profile` and effective
compiler argv when recording evidence; the complete policy is in
[build profiles](../language/build-profiles.md) and the
[test-runner profile contract](test-runner.md#validation-profile-and-isolated-sdks).

Run full validation without ambient `ROCKS_TREE`, `TITAN_ROCKS_ROOT`,
`TITAN_EXTRA_CPPFLAGS`, or `TITAN_NO_LINE_DIRECTIVES`. These alter SDK/provider
selection, fixture preprocessing, or traceback attribution. Make clears
`LUA_PATH`, `LUA_CPATH`, and their Lua 5.5 variants for its test/compiler
invocations; clear them for manual prefix-tool invocations too, especially
after a shell used `luarocks init`. Default-flag tests also clear all
`TITAN_EXTRA_*FLAGS`; explicit build-policy inputs are otherwise caller-owned.

| Command, from the repository root | Purpose |
| --- | --- |
| `make test` | Prepare the selected SDK, reinstall the current compiler/provider, and run the complete mixed suite. |
| `TITAN_JOBS=4 make -j4 test` | Four-way native/generated-C preparation variant. |
| `luarocks test` | Run against an already current install; its active `bin` on `PATH` is sufficient. It does not build the rock. |
| `make rock-test` | Complete Busted and native domains; a cold run re-enters full preparation. |
| `make busted-test BUSTED_FILTER='for loop'` | Busted only. |
| `make stdlib-test` | Complete retained stdlib/runtime category without coverage. |
| `make titan-stdlib-test` | Build and run the aggregate native suite. |
| `make titan-stdlib-test-build` | Build all native roots once. |
| `make titan-stdlib-test-run TITAN_FILTER='^ssl[.]tests[.]'` | Filter a fresh execution of the existing aggregate; never filter compilation. |
| `make rock-test BUSTED_FILTER='parser' TITAN_FILTER='^http[.]tests[.]'` | Independently filter both domains. Neither filter skips the other domain. |
| `make stdlib` / `make install-stdlib` | Incremental standard-provider build / build then copy, using the installed compiler/SDK by default. |
| `make clean-stdlib` | Clear standard-provider outputs before changing tools, flags, profile, or OpenSSL mode. |
| `make clean` / `make distclean` | Remove owned generated artifacts / also remove downloaded native dependency trees. |

Leaf build/run targets require a prepared matching SDK. Default Busted,
`make busted-test`, `luarocks test`, and installed `titanc` use the installed
compiler snapshot. Reinstall after compiler, runtime, or standard-library
changes. `make test` owns this refresh; `luarocks test` alone does not.

For focused compiler Lua edits, use the explicit checkout profile:

```sh
TITAN_ROCKS_ROOT="$PREFIX" TITAN_PROBE_CACHE_DISABLE=1 \
  busted --run=checkout spec/parser_spec.lua
TITAN_ROCKS_ROOT="$PREFIX" TITAN_PROBE_CACHE_DISABLE=1 \
  busted --run=checkout spec/coder/coder_spec.lua --filter='for loop'
```

That profile prepends checkout Lua modules after the LuaRocks launcher's path
setup and keeps the installed SDK/native inputs. An ambient checkout-first
`LUA_PATH` alone does not have that precedence. Scope the root override to
this command; it neither refreshes installed artifacts nor rebuilds the native
aggregate. The [test-runner chapter](test-runner.md#repository-dogfooding)
describes its resolver setup and regressions.

`titanc` accepts dotted module names, not file paths. Use its
[CLI reference](driver.md#the-titanc-command-line) for provider/standalone
selection, `--tree`, incremental object reuse, `-c`, and test mode. Source-rock
`all` uses the in-tree compiler and private bootstrap; ordinary `stdlib` uses
the installed compiler unless `STDLIB_USE_INSTALLED_RUNTIME=0`. Packaging,
binary-rock, and uninstall ownership are documented under
[driver's build and installation contract](driver.md#the-titanc-command-line).

## Preserve fixture and shared-output ownership

All spec paths are relative to the repository-root CWD. Shared compile/check/run
helpers live in `spec/support/helpers.lua`; require them as
`spec.support.helpers`. Set `helpers.verbose = true` to print native commands
and retain generated C. Required modules load `luassert` explicitly because
they do not inherit Busted's assertion global. Helpers touching checker/coder
state reset `types.registry` and, for imports, `driver.imported` first.

Compiler fixtures remove only their exact artifacts, including the paired
`.a` from a no-main compile. Treat `titan-runtime/libtitan.a`, the canonical
`titan.so`/`titan.a`, generated standard shims, and native dependency archives
as shared Make-owned state. Helpers must not invalidate them to force a rebuild.
The bounded cleanup rules for `.titan-tests`, same-stem generated C, synthetic
test suffixes, and interrupted root fixtures are in the
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
