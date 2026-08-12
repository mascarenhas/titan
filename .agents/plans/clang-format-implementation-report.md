# clang-format migration implementation report

## Result

The approved migration is implemented in the shared `feature/ffi-wrapup`
checkout. Titan no longer installs or loads its Lua C reindenter. Every
compiler-materialized C or compiler-owned source-foreign header artifact is
formatted by the configured external `clang-format` command before compilation,
probe consumption, or publication. No commit was created.

## Compiler implementation

`titan-compiler/driver.lua` now exposes `driver.CLANG_FORMAT`, defaulting to
`clang-format`, and uses the existing shell-word parser, argv quoting, command
runner, and verbose-printing conventions. For each generated artifact it
appends these fixed arguments:

```text
-i
--style={BasedOnStyle: LLVM, IndentWidth: 4, SortIncludes: false}
--
<generated path>
```

The explicit style prevents ambient `.clang-format` discovery, while
`SortIncludes: false` preserves generator-controlled include ordering.
Configured commands and paths containing spaces remain single argv words.
Missing, malformed, empty, signaled, or nonzero formatter commands return
ordinary compiler errors with the artifact path and termination detail; they do
not produce Lua tracebacks. `-v` prints the same safely quoted command that is
executed.

The production artifact inventory and failure ordering are:

| Artifact | Ordering and failure behavior |
| --- | --- |
| Preliminary source-dependency `.titan.h` | Write a unique checking temporary, format it, then expose it to C probes. A write/format failure removes the temporary and reports the source-header context. |
| Final public `.titan.h` | Validate all plans/ownership first; write and format a same-filesystem sibling stage; atomically rename it into place. A formatter failure removes the stage, preserves an existing owned header byte-for-byte, and leaves `_foreign_header_prepared` unset. The pre-existing per-header sequential publication contract is retained. |
| Persistent module `.c` | Remove stale output object, write raw C at the canonical diagnostic path, format it, then compile. A formatter failure leaves the C for diagnosis and does not compile or reuse an object. |
| Standalone/`--test` entrypoint `.c` | Remove the stale executable and entrypoint object, write raw C, format it, then compile/link. A formatter failure retains the C and cannot reuse stale native output. |
| Standalone archive-protocol validation `.c` | Write the private temporary, format it, then compile. Its existing cleanup closure removes all probe artifacts on formatter failure. |

Checker-owned `cprobe.lua` snippets are deliberately not formatted: they are
semantic probe inputs, some intentionally rejected C, rather than emitted
codegen artifacts.
Generated multiline C comments use the ordinary ` *` continuation spelling;
this avoids clang-format's non-idempotent first pass over mixed `*`/`**`
continuations and makes each emitted file a fixed point after Titan's single
formatter invocation. Code generation removes every template-introduced blank
physical line immediately after `#line` before formatting, and the final
formatted-file boundary enforces the same invariant before compilation;
otherwise a blank would consume the named source line and shift native traceback
attribution.

`titan-compiler/pretty.lua` and `spec/pretty_spec.lua` are deleted, all live
`pretty.reindent_c` calls/imports are removed, the rockspec module inventory no
longer installs `titan-compiler.pretty`, and the stale coder/variadic comments
were updated.

## Build, packaging, and CI

- `Makefile` defines and exports `CLANG_FORMAT ?= clang-format` to recipe-owned
  compiler processes.
- The exact formatter command is recorded in the standard-library configuration
  stamp, so changing it invalidates a warm generated provider image.
- `make help`, `README.md`, `AGENTS.md`, the active language manual, and the
  implementation manuals document the prerequisite, override, fixed style,
  artifact lifecycle, verbose output, and failure behavior.
- All four compiler-using CI jobs install clang-format independently: Linux
  stdlib producer, Linux compiler consumer, macOS dispatch job, and sanitizer.
- Five installed-compiler test harnesses now prefix the installed Titan `bin`
  while preserving ambient `PATH`, so Homebrew/Linuxbrew/custom formatter
  locations remain discoverable.
- A LuaRocks `external_dependencies.program` entry was intentionally not added.
  LuaRocks 3.13 searches configured external-dependency prefixes instead of the
  supported ordinary `PATH`/custom `CLANG_FORMAT` command and would reject
  valid Homebrew or wrapper configurations. The formatter is a documented
  runtime compiler prerequisite and is resolved by Titan itself.
- A clean `$HOME/.local/titan` source-rock reinstall removed the formerly
  installed `pretty.lua`; the installed driver and rock manifest contain the
  new inventory.

Current documentation was migrated away from the retired reindenter. Historical
Lua migration notes were qualified as describing the former pass rather than
rewritten as if it had never existed. The implementation was independently
reviewed in `.agents/plans/clang-format-integration-audit.md`; its generated-file
inventory found no production gap. The focused test design is recorded in
`.agents/plans/clang-format-test-plan.md`.

## Focused validation

All commands below passed against the live shared checkout/current installed
snapshot:

- `luac -p` over every changed Lua file plus `titanc`.
- `git diff --check`.
- `spec/driver_spec.lua`: **82 successes** (argv/quoting, verbose behavior,
  malformed/empty/missing/nonzero failures, and transactional header tests).
- `spec/coder/driver_flags_spec.lua`: **9 successes** (real compiler ordering,
  `CLANG_FORMAT` environment handling, and exit-23 before-compile behavior).
- `spec/coder/foreign_functions_spec.lua`: **5 successes** (real
  one-pass clang-format fixed points for generated module C (including protected-boundary multiline comments) and `.titan.h`, plus compile
  and runtime behavior).
- `spec/coder/multi_module_grouping_spec.lua`: **4 successes** (including the
  persisted standalone entrypoint fixed-point assertion).
- `spec/coder/multi_module_libraries_spec.lua` filtered direct-source header
  case: **1 success**.
- `spec/libuv_build_spec.lua` filtered Make/configuration/CI contract case:
  **1 success**.
- `spec/rockspec_spec.lua`: **7 successes** (installed file and manifest
  inventory included).
- `$PREFIX/bin/luarocks make titan-dev-1.rockspec`: succeeded, including the
  eighteen-root standard-provider post-install build/publication.
- Manual real-tool smoke with a generated path containing spaces: succeeded.
- Manual missing-formatter compiler smoke: exited 1 with the generated path and
  exit 127 in the diagnostic, retained raw module C, and created no object.
- Manual standalone verbose smoke confirmed both the module and
  `__entrypoint.c` formatter invocations precede their C compilation commands.
- `make help`: succeeded and prints the new supported-platform prerequisite.

The complete mixed suite and dispatch-only macOS CI were not run locally; they
remain normal parent/pre-merge gates. No files were committed.
