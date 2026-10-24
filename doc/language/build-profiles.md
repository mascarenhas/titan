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

## Split modules

A module whose generated C definitions reach 2 MiB can be split into
several C translation units, which then compile as independent jobs under the
same bound. `titanc --c-parts N` or `TITAN_C_PARTS=N` sets the maximum number
of units per module; the command-line option wins, and the value must be a
positive integer. `1` disables splitting. The default is 4 on Linux and 1 on
macOS, Windows, and other platforms, so splitting is opt-in there. Smaller
modules always stay in one unit. The part count is independent of `--jobs`:
changing the job bound never changes generated files, while changing the part
count changes them and makes previously compiled objects stale
([incremental compilation](incremental-compilation.md#what-object-reuse-promises)).
In a Titan checkout, the Make targets that compile the standard library and
the native tests record `TITAN_C_PARTS` and recompile every module object once
after it changes; changing only `TITAN_JOBS` or `make -j` recompiles nothing.
The extra generated files are listed in [Output
directories](output-directory.md#source-hierarchy-and-final-outputs).

## Build and test parallelism

In a Titan checkout, the Make targets that compile many modules (`make stdlib`,
`make stdlib-objects`, `make titan-stdlib-test-objects`, and
`make titan-stdlib-test-build`) and the build that `luarocks make` runs share
one GNU Make job pool. Without a `-j` option, GNU Make 4.2 or later creates
one pool of `TITAN_JOBS` slots, four by default, so independent modules and
the parts of large modules compile side by side within that budget. An
explicit `make -jN`, or the pool of a parent Make, takes precedence:
`make -j8 stdlib` runs at most eight jobs in total, and `TITAN_JOBS` then only
caps each `titanc` run inside it. `make -j1` builds serially.

GNU Make before 4.2, including macOS's stock 3.81, cannot tell `make -j1` from
plain `make`. With such a Make, `make` and `make -j1` both build serially, and
each `titanc` compiles with one job, unless you set `TITAN_JOBS` in the
environment or on the command line: `TITAN_JOBS=4 make stdlib` creates the
four-slot pool. `make -jN` still runs `N` modules at once. macOS users get the
four-job default either with GNU Make 4.2 or later first on `PATH` (Homebrew's
`make` formula installs it as `gmake`) or by setting `TITAN_JOBS`. On macOS,
each `titanc` in a pool still compiles with one job until GNU Make 4.4 or
later, which also compiles a large module's parts in parallel.

The repository's test commands use the same budget:

* `make busted-test`, `make rock-test`, `make test`, and `luarocks test` run
  each Busted spec file once across `TITAN_ROCK_TEST_JOBS` workers, each in a
  private copy of the checkout. Every worker holds one slot of the shared
  pool. `make rock-test` also builds the native test executable inside that
  pool, so it defaults to three workers beside the build; `make busted-test`
  defaults to four. A four-slot budget therefore runs four jobs in total.
  Workers beyond the pool's slots wait for a free one, so raise both settings
  together on a larger machine, for example
  `TITAN_JOBS=8 TITAN_ROCK_TEST_JOBS=7 make rock-test`. With GNU Make before
  4.2 and no `TITAN_JOBS`, the workers instead share a pool with one slot per
  worker plus one for the native build, whose `titanc` runs use one job each.
* `make titan-stdlib-test` and the native phase of `make rock-test` run the
  built native test executable as `TITAN_TEST_JOBS` groups of test owners at
  once (default four; `1` runs them one group at a time), then run the
  timing-sensitive owners alone. `make titan-stdlib-test-run` stays one
  focused process, and `TITAN_FILTER` selects it.
* A failing spec file or test group does not stop the others. Each command
  finishes its remaining work, lists every failure, and then fails.

Native coverage runs and native Windows test runs keep one native test process.
On Windows, `TITAN_JOBS` (default four) is the only native build-parallelism
setting; see [Windows native build
parallelism](../implementation/windows-build.md#native-build-parallelism). The
[repository workflow](../implementation/repository-workflow.md#choose-the-matching-profile-and-command)
lists the commands, and [build and installation
responsibilities](../implementation/build-script-audit.md#make-job-pool-and-titanc-recipes)
describe the exact pool rules.
