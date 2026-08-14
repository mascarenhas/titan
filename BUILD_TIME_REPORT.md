# CI build-time investigation and generated-source formatting report

## Scope and conclusion

This branch starts from `origin/master` at `9b7369e042b59c654cab2eb79f86fc0212b2b582` and addresses the bounded driver work requested after the CI regression first visible at `57a16f4d5a500e73261ff25c389daba2ec00ee2f`.

Two repeated costs were confirmed rather than inferred:

1. Every generated C/header boundary synchronously ran `clang-format`, including very large generated translation units. The 22-root native test build crossed 42 such boundaries.
2. Source-foreign companion headers were rendered before final source-header identities were wired, rendered again after wiring, and then rendered a third time by `coder.generate` even though the driver had already published the final header. Modules with no source-foreign function still took a redundant `generate_foreign_header` walk at the end of code generation.

The driver implementation makes formatting explicitly opt-in with `titanc --pretty-print`, retains mandatory `#line` blank-line normalization in every mode, and makes invocation-wide foreign-header planning/rendering single-pass after identities are final. The generics branch additionally applies the separately profiled, semantics-preserving expression-suffix parser refactor described below; it does not attempt the riskier checker graph-clone or C-code-size changes. No change increases a CI timeout.

The controlled native multi-root build improved from **141.84 s** with the old default formatter path to **111.30 s** with the new default, a single-host observation of **30.54 s / 21.5%**. This is a controlled before/after observation, not a statistical benchmark and not a claim that the full historical multi-minute regression is eliminated.

## Historical CI evidence

The retained GitHub logs are `/tmp/titan-ci-logs/run-80be3a1.log` and `/tmp/titan-ci-logs/run-57a16f4.log`, from runs `31527685175` and `31622524108`. Extracted phase durations were:

| CI phase | `80be3a1` | `57a16f4` | Change |
|---|---:|---:|---:|
| sanitizer job | 1387.7 s (23.13 m) | 1752.0 s (29.20 m) | +364.3 s |
| sanitizer `titan-artifacts` | 460.3 s | 669.6 s | +209.3 s |
| sanitizer native stdlib build | 631.4 s | 783.4 s | +152.0 s |
| regular stdlib `luarocks make --force` | 269.3 s | 363.1 s | +93.8 s |
| regular `stdlib-test` | 262.1 s | 334.2 s | +72.1 s |
| regular system reinstall/smoke | 160.5 s | 248.4 s | +87.9 s |
| compiler/language job | 770.3 s | 1144.3 s | +374.0 s |

This distribution supported investigating work repeated across ordinary provider generation and the native multi-root build rather than raising timeouts. The patch recovers a measured portion of that cost; generated-C size and the native compiler/checker work added by the historical feature remain outside this narrow change.

## Implementation

### Opt-in presentation formatting

`titanc` now accepts:

```text
--pretty-print    Format generated C and headers with clang-format.
```

The option is threaded through the resolver context and the driver paths that own:

- source-checking temporary foreign headers;
- finalized source-foreign companions;
- module translation units;
- standalone/test entrypoints; and
- the generated standalone archive protocol probe.

`driver.format_generated_file(filename, verbose, pretty_print)` now parses and runs `CLANG_FORMAT` only when `pretty_print` is true. In the default mode even a missing, empty, or malformed `CLANG_FORMAT` is inert. In opt-in mode the prior contract is unchanged: the command receives `-i`, Titan's fixed LLVM-derived four-space style, `SortIncludes: false`, `--`, and the exact generated path; verbose mode prints the safely quoted argv; a formatter failure prevents compilation/publication.

After the optional presentation pass, the driver always reads the file and removes every blank physical line immediately following a `#line` directive. `coder.generate` retains the same normalization on assembled module source. Therefore source attribution does not depend on installing or running a formatter.

Ordinary Linux, sanitizer, compiler-consumer, and macOS CI dependency installation no longer installs `clang-format`. Tests of the opt-in command use controlled fake commands (`true` for success and a failing `sh` command for failure), so the default CI graph does not regain a formatter dependency through its test suite. A separate controlled `--pretty-print` timing run used real `clang-format`.

The unused `CLANG_FORMAT` value was removed from the supported default stdlib configuration stamp. `CLANG_FORMAT` remains exported/configurable for explicit `--pretty-print` invocations. The three existing `timeout-minutes: 30` entries are byte-for-byte unchanged.

### Single final source-foreign render

`driver.plan_foreign_headers` now:

1. derives all final output identities and detects collisions without rendering;
2. marks whether each AST actually has source-foreign functions;
3. rewrites direct source-import edges to the finalized absolute companion paths;
4. renders each required final header once; and
5. validates every destination before publication.

After a plan is successfully written, its raw generated contents (including `nil` for a module with no companion) are retained as `_foreign_header_contents` beside the existing `_foreign_header_prepared` phase marker. `coder.generate` consumes this finalized result instead of walking/rendering the checked AST again. A direct programmatic `driver.compile` that has no prepared plan retains its one-module fallback.

The recursive loader's temporary checking header is intentionally retained: consumers need it while source checking is still recursive and before final physical identities exist. This is necessary work, not a cache miss. For a real source-foreign module the lifecycle is now one checking render plus one final render, rather than checking + pre-final + final + ignored coder render.

No provider registry, cross-invocation cache, alternate identity mechanism, or trust-boundary workaround was introduced.

## Controlled local evidence

All runs used:

- worktree `/tmp/titan-ci-build-time-wt`;
- isolated prefix `/tmp/titan-ci-build-time-prefix`;
- the same installed Lua 5.5/Titan SDK, host, target, and C toolchain;
- `TITAN_EXTRA_CFLAGS=-O0`;
- a removed `.titan-tests` before every run; and
- no ambient Lua paths, rocks-tree override, explicit Titan path, extra flags, or line-directive override.

The measured command shape was:

```sh
rm -rf .titan-tests
/usr/bin/time -f 'elapsed=%e user=%U sys=%S maxrss=%M' \
  make titan-stdlib-test-build \
    PREFIX=/tmp/titan-ci-build-time-prefix \
    TITAN_EXTRA_CFLAGS=-O0 \
    TEST_TITANC="$TEST_TITANC"
```

The baseline used the clean installed baseline compiler. After-change runs forced the working-tree `titanc` through the same prefix Lua and SDK. The no-op formatter control set `CLANG_FORMAT=true`; the opt-in run appended `--pretty-print` to `TEST_TITANC`.

| Variant | Elapsed | User | System | Max RSS |
|---|---:|---:|---:|---:|
| baseline, old real-formatter default | 141.84 s | 133.41 s | 7.90 s | 520544 KiB |
| baseline, 42 formatter boundaries using `true` | 125.92 s | 119.53 s | 5.90 s | 485364 KiB |
| after, new default (clean repeat) | **111.30 s** | 105.12 s | 5.80 s | 486368 KiB |
| after, real `--pretty-print` | 135.90 s | 127.90 s | 7.53 s | 520740 KiB |
| after, default with lightweight counters | 113.14 s | 106.96 s | 5.79 s | 485912 KiB |

The baseline real-vs-`true` split is 15.92 s and the after default-vs-real-pretty split is 24.60 s. Host and cache variation are visible, so the remaining 14.62 s between baseline-`true` and after-default is **not** attributed wholesale to header scans. The call counts below are the causal evidence for that separate driver fix.

Lightweight, temporary counters (removed before the committed diff) observed:

| Native multi-root build | output-boundary calls | formatter subprocesses | `generate_foreign_header` calls |
|---|---:|---:|---:|
| baseline | 42 | 42 | 41 |
| after, default | 42 | 0 | 0 |

All 41 baseline header calls were unique no-source-foreign modules and returned after the redundant end-of-codegen scan. The focused planner spec separately uses two source-foreign ASTs and asserts exactly one finalized render per plan, covering the more expensive pre-final/final duplication. The cached prepared contents remove the later ignored coder render.

Representative one-file formatter samples from baseline-generated output further show why the subprocess is not negligible:

| Generated file | Size | `clang-format` elapsed |
|---|---:|---:|
| `titan/uv/uv.c` | 6.25 MB | 6.08 s |
| `titan/string/string.c` | 4.67 MB | 4.15 s |
| `titan/peg/peg.c` | 3.07 MB | 2.25 s |
| `titan/async.c` | 3.32 MB | 1.87 s |
| test runner C | 2.79 MB | 1.84 s |

Raw evidence is retained under `/tmp/titan-ci-logs/`, including `baseline-native-stdlib.log`, `baseline-native-true-formatter.log`, `after-native-stdlib2.log`, `after-native-stdlib-pretty.log`, `instrument-native2.log`, `after-native-stdlib.log`, and `formatter-per-file.csv`.

A warm post-change `luarocks make --force` completed successfully in 225.88 s (`after-install-warm.log`). It is validation only: the available 424.63 s earlier observation was cold and is not presented as a controlled delta.

## Generics parser integration

A separate controlled profile of `generics-v1` found that the remaining
branch-specific native-suite compiler delta was concentrated in expression
parsing: 72 aggregate sources took 83.27 CPU-s in instrumented full builds
versus 67.01 CPU-s on the matching master tree. The original suffix grammar
replayed generic/ordinary and positional/named alternatives, and parsed a
method's `: Name` prefix up to four times. Even 49 byte-identical sources were
16.3% slower.

The integrated parser change left-factors that grammar. One bounded generic
lookahead proves a complete list followed by a call delimiter or nominal-member
dot, after which one branch selects positional/named call arguments or the
owner member. Methods consume `: Name` once before selecting a generic call or
bound-method reference. The public grammar, AST, diagnostics, comparison
fallback, owner-attached syntax, and checker contract are unchanged; successful
lists retain the conservative lookahead-plus-capture scan. The measured proof
of concept reduced the direct 72-source parser benchmark from 60.36 to 50.40
CPU-s (-16.5%). The final integrated tree, measured against its unmodified
parent on the same 72 files and host, reduced 61.006 to 49.379 CPU-s (-19.1%)
and preserved all 839 top-level nodes. Parser/lexer validation passed 203/203,
and the generic checker suite passed 27/27.

## Tests and review

Final focused validation in the isolated prefix:

- Lua syntax for every changed Lua source/spec: passed.
- `spec/driver_spec.lua`: **86/86**.
- `spec/coder/driver_flags_spec.lua`: **11/11**.
- `spec/coder/foreign_functions_spec.lua`: **5/5** under the new raw default.
- `spec/coder/multi_module_grouping_spec.lua`: **4/4**; the standalone/entrypoint opt-in path uses `CLANG_FORMAT=true`, avoiding a CI package dependency.
- Combined final focused run: **106/106** (`/tmp/titan-ci-logs/final-focused.log`).
- Make/provider/workflow contract focus: **1/1**.
- Real source-foreign provider/consumer chain: **1/1** (`final-contracts.log`).
- Clean default native multi-root build: passed.
- Real `--pretty-print` native multi-root build: passed.
- Aggregate native executable: **186/186** (`native-run-after.log`).
- Warm installed rock rebuild: passed.
- Installed CLI smoke: default compilation and execution succeeded with `CLANG_FORMAT=definitely-missing`; `--pretty-print` failed before compilation with the expected formatter error; `--help` listed the option.
- `.github/workflows/ci.yml` parses as YAML; timeout entries match the baseline exactly.
- `git diff --check`: passed.

The final review removed accidental generated `*.titan.h.check.tmp.*` files. It also removed the initial draft's real-`clang-format` fixed-point calls from ordinary compiler specs: keeping those while removing the CI package would have left an undeclared dependency. Opt-in success/failure and exact argv remain covered without requiring the tool; the controlled real-formatter build supplies the integration evidence.

## Remaining limits

- This task did not run the hosted Linux graph or the dispatch-only macOS job.
- The timing observations are controlled single-host runs, not a repeated statistical sample.
- The patch removes confirmed presentation and duplicate-header work, but it does not claim to recover the full historical CI regression. Further work should require similarly localized phase/call-count evidence rather than a speculative compiler rewrite.
