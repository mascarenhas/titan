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
TITAN_EXTRA_LDFLAGS='-Og -g -fno-lto' titanc --incremental -o out app.main
```

Extra environment flags and command-line `--cflag` / `--ldflag` options follow
the profile defaults. The later `-g` restores full debug information for both
GCC and Clang, including ordinary variable tracking, and matching link flags
disable Linux LTO at link time. With `--incremental`, changing compile flags
automatically invalidates module object certificates (`configuration options`),
while changing link-only flags invalidates only the final-link certificate.

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

`titanc --jobs N` (`-j N`) or `TITAN_JOBS=N` sets the maximum number of
concurrent module-frontend worker processes and native compiler jobs one
`titanc` invocation may run at once on Linux, macOS, and Windows. The
command-line option wins, and the default is four.

One coordinator process owns a single slot ledger for the invocation. Modules
whose `.titan.source` certificates hit are restored in-process without starting
a worker; a warm build where every module hits spawns no workers and opens no
job pool. Modules that miss run in short-lived worker processes under the
ledger. When a worker launches a batch of generated-C part compilations or C
validation probes, its first native job inherits the worker's active slot and
any additional batch jobs acquire free ledger slots; the worker resumes Lua
execution once its batch finishes and returns the slot. Diagnostics and
captured worker output are buffered and flushed in deterministic plan order, so
the job count never changes generated C or diagnostic ordering. With
`--jobs 1`, `TITAN_JOBS=1`, or (on Linux and macOS) under `make -j1`, `titanc`
uses one slot and runs each C probe as it is reached. Library builds also use
the slot bound for their two provider links: the second link overlaps the first
only when a shared parent GNU Make jobserver grants a token, and every
validation still precedes publication.

On Linux and macOS, a `titanc` recipe marked with `+` in a GNU Makefile shares
a parent GNU Make 4.4 or newer FIFO jobserver (`--jobserver-auth=fifo:...`), or
a pipe jobserver on Linux where `titanc` can reopen `/proc/self/fd` privately.
Its first active worker or native job uses the recipe's implicit slot and each
further active job borrows one token from Make, so `make -j8` runs at most
eight jobs in total while `--jobs` still caps each `titanc` invocation. Under
`make -j1`, `titanc` runs serially. When a parent Make advertises a valid
inherited pipe jobserver that the platform cannot reopen privately—such as
macOS's stock GNU Make 3.81, GNU Make earlier than 4.4 on macOS, or
`--jobserver-style=pipe` on macOS—`titanc` prints one warning and uses its own
local `--jobs` / `TITAN_JOBS` cap without borrowing from the parent pool;
sharing a parent Make pool on macOS requires GNU Make 4.4 or later (Homebrew
`gmake`). When Make advertises a jobserver whose descriptors are unusable
because the recipe was not marked with `+`, `titanc` warns once and runs with
one job. Windows applies only the local `--jobs` / `TITAN_JOBS` bound. See
[GNU Make jobserver participation](../implementation/driver.md#gnu-make-jobserver-participation).

## Split modules

A module whose generated C definitions reach 2 MiB can be split into several C
translation units, which then compile as independent jobs under the same slot
ledger. `titanc --c-parts N` or `TITAN_C_PARTS=N` sets the maximum number of
units per module; the command-line option wins, and the value must be a
positive integer. `1` disables splitting. The default is 4 on Linux and 1 on
macOS, Windows, and other platforms, so splitting is opt-in there. Smaller
modules always stay in one unit.

The part count is independent of `--jobs`: changing the job bound never changes
generated files, whereas `--c-parts` is recorded in each module's
`.titan.source` object certificate (`codegen-options c_parts`) and the primary
`<stem>.o` record owns the authoritative `parts` inventory. With
`--incremental`, changing `--c-parts` or `TITAN_C_PARTS` misses with
`codegen-options c_parts`, recompiles the module, and retires any obsolete
`.part<k>.c`/`.o` or `.priv.h` companions
([Incremental and separate compilation](incremental-compilation.md#what-object-reuse-promises)).
The extra generated files are listed in
[Output directories](output-directory.md#source-hierarchy-and-final-outputs).

## Build and test parallelism

In a Titan checkout, `make stdlib`, `make stdlib-objects`,
`make titan-stdlib-test-objects`, `make titan-stdlib-test-build`, and the build
that `luarocks make` runs invoke `titanc --incremental -j$(TITAN_JOBS)` in `+`
recipes. Without a `-j` option on Make, GNU Make 4.2 or later defaults
`TITAN_JOBS` to four, so `titanc` schedules module workers, probe batches, and
split-module C parts across four slots. With GNU Make 4.4 or later (or on
Linux), an explicit `make -jN` or parent Make FIFO/pipe pool is shared across
recipes and `TITAN_JOBS` caps each `titanc` invocation inside it; `make -j1`
builds serially.

GNU Make before 4.2, including macOS's stock 3.81, cannot distinguish `make -j1`
from plain `make`. With such a Make, `TITAN_JOBS` defaults to `1` so plain
`make` and `make -j1` both build serially unless you set `TITAN_JOBS` explicitly
(for example, `TITAN_JOBS=4 make stdlib`). On macOS, putting GNU Make 4.4 or
later first on `PATH` (Homebrew's `make` formula installs it as `gmake`) enables
both the four-job default and shared FIFO jobserver pools; under older Make on
macOS, setting `TITAN_JOBS=4` gives each `titanc` invocation its local four-job
cap without sharing the parent pipe pool.

The repository's test commands use the same budget:

* `make busted-test`, `make rock-test`, `make test`, and `luarocks test` run
  each Busted spec file once across `TITAN_ROCK_TEST_JOBS` workers, each in a
  private copy of the checkout. Every worker holds one slot of the shared Make
  pool. `make rock-test` also builds the native test executable inside that
  pool, so it defaults to three workers beside the build; `make busted-test`
  defaults to four. A four-slot budget therefore runs four jobs in total.
  Workers beyond the pool's slots wait for a free one, so raise both settings
  together on a larger machine, for example
  `TITAN_JOBS=8 TITAN_ROCK_TEST_JOBS=7 make rock-test`.
* `make titan-stdlib-test` and the native phase of `make rock-test` run the
  built native test executable as `TITAN_TEST_JOBS` groups of test owners at
  once (default four; `1` runs them one group at a time), then run the
  timing-sensitive owners alone. `make titan-stdlib-test-run` stays one
  focused process, and `TITAN_FILTER` selects it.
* A failing spec file or test group does not stop the others. Each command
  finishes its remaining work, lists every failure, and then fails.

Native coverage runs and native Windows test runs keep one native test process.
On Windows, `TITAN_JOBS` (default four) bounds both module workers and native C
compilations; see
[Windows native build parallelism](../implementation/windows-build.md#native-build-parallelism).
The [repository workflow](../implementation/repository-workflow.md#choose-the-matching-profile-and-command)
lists the commands, and
[build and installation responsibilities](../implementation/build-script-audit.md#make-job-pool-and-titanc-recipes)
describe the exact pool rules.
