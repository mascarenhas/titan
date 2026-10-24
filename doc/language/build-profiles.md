# Native build profiles

Ordinary Titan compilation and installation use the `production` profile. Its
generated C uses `-O3`, with `-flto=auto -ffat-lto-objects` on Linux. Darwin and
Windows retain `-O3` without default LTO.

Production debug information is tailored to the configured C compiler:

- GCC uses `-g1`, retaining function names and source lines for backtraces while
  omitting local variables and disabling variable and assignment tracking.
- Clang uses `-gline-tables-only -fdebug-info-for-profiling`. Line tables omit
  variable debug information; the profiling option preserves function records
  that Titan's traceback symbolizer needs, including ordinary callback frames.
- Other compilers conservatively retain `-g`.

Titan identifies the compiler through its predefined macros, including when
`CC` names a wrapper or a command with arguments. Clang takes precedence over
its GCC compatibility macros. Titan source attribution through `#line` remains
enabled.

For an interactive debugger build, restore full debug information and select
debug-friendly optimization in both compile and link flags:

```sh
TITAN_EXTRA_CFLAGS='-Og -g -fno-lto' \
TITAN_EXTRA_LDFLAGS='-Og -g -fno-lto' titanc app.main
```

These extra flags follow the defaults. The later `-g` restores full debug
information for both GCC and Clang, including ordinary variable tracking.
Supplying matching link flags also covers Linux LTO. Rebuild existing objects
when changing flags.

Set `TITAN_BUILD_PROFILE=validation` for development and validation builds:

```sh
TITAN_BUILD_PROFILE=validation make lua luarocks PREFIX="$PWD/.lua-validation"
TITAN_BUILD_PROFILE=validation .lua-validation/bin/luarocks make --force
TITAN_BUILD_PROFILE=validation .lua-validation/bin/luarocks test
```

The validation profile retains `-g` without disabling variable tracking and uses
`-O0 -fno-lto` for generated code, the Titan native
runtime and bundled standard-library payloads. Lua and its compiler dependencies
(LPegLabel and Lua filesystem), plus the private LPegLabel payload, stay optimized
at `-O2 -fno-lto`: the Lua-written compiler and its tests execute through them.
Sanitizer builds use `-O1 -fno-lto` for those host/parser components while retaining
all ASan/UBSan instrumentation; Titan code and other native payloads remain O0.

`make luarocks` installs stock LuaRocks and leaves native Lua dependency builds
at its ordinary optimized defaults. Titan's runtime build receives the separate
profile-specific `ROCK_CFLAGS`. For sanitizer installations, build LPegLabel and
Lua filesystem explicitly through LuaRocks with the required instrumented
`CFLAGS` and `LDFLAGS` before installing Titan. `LPEGLABEL_BUILD_CFLAGS` selects
the private parser payload; its flags follow generic Titan extras so an O0
fixture setting cannot deoptimize that parser. Explicit domain overrides remain
caller-owned, including sanitizer instrumentation.

Use a separate prefix for each profile. Lua and LuaRocks preparation only checks
for their programs in `PREFIX/bin`; clean Lua objects and remove or replace the
installed programs yourself when changing their build inputs. The default repository test commands
select validation and use `.lua-validation` when no `PREFIX` was supplied;
ordinary builds retain existing active-PATH Lua prefix discovery. A discovered
prefix remains caller-owned: select a matching profile or pass an explicit
separate production PREFIX when the active SDK is validation. `make test` prepares
and reinstalls Titan in the selected toolchain before running the complete gate. A cold
`make rock-test` prepares its missing validation prefix through `make test`.
Leaf native build/run targets require that selected SDK to be prepared already.

Native Windows Make check and test targets select the same validation profile,
with separate `.windows-sdk-validation` and `out/windows-validation` defaults.
Ordinary Windows Lua, native dependency and runtime builds retain their existing
`-O2` defaults; generated Titan C retains the production `-O3` policy. Explicit
`PREFIX`, `WINDOWS_BUILD_ROOT` and native flags remain caller-owned.
Windows also defaults to `OPENSSL_MODE=system`, so its installed binary OpenSSL
keeps the provider's build flags. Select `OPENSSL_MODE=bundled` to build the
pinned OpenSSL source with the selected native profile.

An installed SDK records its selected profile in `etc/titan/build-profile`.
On Unix, run `make clean-stdlib` before changing the standard provider's flags,
tools, profile, or OpenSSL mode. On Windows, clean the selected private build
directory and generated provider outputs. On Unix, the bundled libbacktrace and
libuv builds record their profile, compiler, and flags and rebuild once when
they change ([configuration
stamps](../implementation/build-script-audit.md#native-dependency-configuration-stamps)).
Clean the other native build directories (llhttp, SQLite, OpenSSL, and every
Windows native build) when changing their inputs; Make does not save or
reconcile those settings.
Native outputs remain adjacent to their sources, so builds using the same
checkout must run sequentially even when their installed prefixes differ. Use
separate source copies for concurrent builds.

Only `production` and `validation` are accepted. The profile changes native
build policy without changing the language, ABI, compiler release, or metadata
schema versions. A small compiler smoke continues to test unset production
optimization and cross-module LTO while ordinary validation fixtures stay at
`-O0`.

## Compiler jobs and GNU Make

`titanc --jobs N` or `TITAN_JOBS=N` sets how many generated-C compilations one
`titanc` run may execute at once on Linux, macOS and Windows. The command-line
option wins, and the default is four. Checking, C generation and formatting stay
serial. Library builds also use the bound for their two provider links: the
second link overlaps the first only when a parent GNU Make jobserver grants it a
slot; every validation still precedes publication. Windows stdlib builds also
honor `TITAN_JOBS`.

A `titanc` recipe marked with `+` in a GNU Make file shares Make's jobserver.
Its first compilation uses the recipe's own job slot and each further one
borrows a slot from Make, so `make -j8` runs at most eight jobs in total, while
`--jobs` still caps each `titanc` run. Under `make -j1` titanc compiles
serially. When Make advertises a jobserver that titanc cannot use, titanc prints
one warning and compiles with one job. That includes a recipe without `+` under a
pipe jobserver (GNU Make before 4.4, or 4.4 with `--jobserver-style=pipe`) and
every recipe under macOS's stock GNU Make 3.81; mark each `titanc` recipe with
`+`, and use GNU Make 4.4 or later (Homebrew `gmake`) for parallel compilation
inside Make on macOS.
Windows applies only the `--jobs`/`TITAN_JOBS` bound. See [GNU Make jobserver
participation](../implementation/driver.md#gnu-make-jobserver-participation).
