# Standard-library improvements

Status: implementation is underway on `agent/stdlib-improvements`. Repository
research established the contracts below; the maintainer's corrections are
fixed decisions, and the researched defaults for process/runtime behavior are
adopted unless implementation exposes a genuine architectural contradiction.

This work discharges the `minimal standard library, continued` roadmap item.
It keeps the Titan ABI at **0.20** and is a standard-library project: do not
change the compiler to make an API convenient. If a requested API cannot be
expressed using current Titan semantics, stop and align on the intended
language or library model instead of adding a compiler workaround.

## Fixed constraints and resolved draft corrections

- Preserve all existing standard-library behavior unless this plan explicitly
  changes it. Refactoring existing Titan code is welcome when it clarifies
  ownership or extracts a reusable pattern.
- Add the four logical modules `titan.math`, `titan.lua`, `titan.iter`, and
  `titan.gc`. Together with the ten current roots, the canonical provider will
  contain fourteen logical metadata keys and fourteen generated shims (plus
  the bare native `luaopen_titan` support opener).
- Use qualified imports for those four new modules. They resolve today and do
  not require edits to the compiler's short-import table. Every established
  standard module continues to use its compiler-provided short import even
  inside stdlib sources; spelling one as `"titan.<name>"` is a style
  violation.
- Titan generic-for tuples are `(iterator, state, initial_control, close)`.
  Therefore `iter.pairs` returns `next, map, nil, nil`; the original draft's
  reversed tuple and `map.pairs` example were typos.
- Titan has no `number` source type. Examples use `integer`, `float`, or
  `value` as appropriate.
- Regex strings spell backslashes as `"\\\\w+"`, `"\\\\s+"`, and so on.
- Keep string structurally conformant to the `io` interfaces without importing
  `io`; this avoids the cycle `string -> io -> os -> string`.
- Stdlib modules that already import `string` use `string.writer()` for
  incremental assembly. Retire their private `join_chunks` helpers and audit
  the full source inventory so another copy is not left behind.
- `StringWriter` is the one string-builder record: its private chunk Array and
  checked total length replace the former private `CoreStringBuilder`, and
  string's own formatting/packing/regex internals use that same record.
- `titan.gc` is the sole stdlib owner of raw weak-Map metatable setup. PEG and
  string pass their typed private caches through `gc.weak` instead of calling
  `lua_setmetatable` themselves.
- Use nil-terminated Reader methods directly as generic-for iterators when no
  richer state machine is required, and pass empty chunks through unchanged;
  nil alone denotes EOF. Closures capture parameters and `self` directly, so
  do not introduce aliases whose only purpose is purported rooting. Method
  receivers auto-unwrap options, so a checked optional calls its method
  without a cast-only receiver expression.
- Make repeat-call safety part of the structural `io.Closer` contract. A
  terminal close becomes a no-op; a concrete resource may retry a pre-commit
  failure. Iterator helpers rely on that contract instead of adding a second
  close-once wrapper, closed-state bit, or iterator-state record.
- User-visible additions update both manuals in the same change. All standard
  library behavior specs remain outside LuaCov.

## Resolved public and runtime decisions

### D1. Deliberately typed numeric API

Maintainer decision: omit `math.type`. Do not add a language primitive, inspect
Lua's internal `TValue`, or make a Lua-API exception for it.

Lua 5.5 preserves the run-time integer/float tag in `abs`, `ceil`, `floor`,
`fmod`, `modf`, `max`, `min`, and `tonumber`, and exposes that tag through
`math.type`. The latter is now out of scope. Titan still has no overloads, and
its public gradual test deliberately accepts an integral float such as `2.0`
as `integer`, so source Titan cannot preserve the original tag through all of
the remaining representation-polymorphic functions. Inspecting `TValue`/Lua
internals would contradict the explicit requirement that `titan.math` not use
Lua or the Lua API.

Use a deliberately typed Titan math API: float transcendental and
representation-polymorphic numeric functions, integer-specific functions, and
documented differences from Lua where Titan's static type model cannot preserve
a dynamic numeric tag. No language primitive or Lua-internal escape hatch is
part of this branch.

Related facts that the chosen contract must address:

- Lua `max`/`min` can order arbitrary Lua values through `<` and metamethods;
  Titan has no operator overloading. A numeric-only Titan contract is the
  natural library boundary.
- Lua 5.5 random uses xoshiro256**, two seed words, and unbiased range
  projection. ISO C `rand` is not equivalent. If Lua-compatible behavior is
  required, port the algorithm in Titan and use C only for weak default seed
  entropy; do not substitute `rand`.
- `math.tonumber` needs an integer-first Lua lexical parser (including signed
  decimal/hex forms, whitespace, and bases 2..36), not an unchecked `strtod`
  wrapper that also accepts C-only `inf`/`nan` spellings.

The unambiguous typed portion is:

```titan
acos/asin/cos/deg/exp/rad/sin/sqrt/tan(x: float): float
atan(y: float, x: float?): float
frexp(x: float): (float, integer)
ldexp(m: float, exponent: integer): float
log(x: float, base: float?): float
log2/log10(x: float): float
ult(m: integer, n: integer): boolean

huge: float
pi: float
maxinteger: integer
mininteger: integer
```

### D2. Parent stdio kinds, direction, and lifetime

The current process streams are child-facing: `Process.stdin` is writable and
`Process.stdout`/`stderr` are readable. Parent stdin has the opposite direction
from `Process.stdin`, and parent stdout/stderr have the opposite direction from
the corresponding readable child fields. An inherited descriptor therefore
cannot simply be stored in the current `ProcessControl` slot as the draft
sketch suggested.

In addition, a libuv stream handle belongs to one loop generation. A child
process owns and closes its current three pipe handles; borrowed global parent
stdio must survive child exit, multiple concurrent children, and sequential
Runtime generations. It needs a separate borrowed/per-generation lifetime.

The public contract must say what `Process.stdin`, `stdout`, and `stderr`
contain when the corresponding child descriptor is inherited. The recommended
shape is to make those fields optional: a newly created parent-side pipe is
present, while an inherited child descriptor has no parent-side endpoint and
is `nil`. Merged captured output remains one non-nil `InputStream` value stored
in both fields.

`InputStream` and `OutputStream` are ordinary process-stdio records, not
unions. They cover the Titan process and spawned processes only. `fs.File`
and `net.Connection` remain separate records which structurally implement the
relevant `io` interfaces; neither is an `InputStream` or `OutputStream` merely
because its native resource can be read or written.

The union belongs at the private native-handle boundary: one low-level stdio
wrapper holds either an owned `uv_pipe_t` or `uv_tty_t`. Native kind is the
only variant distinction, and `is_tty()` is exactly a query of that handle
variant. Captured child endpoints carry pipe handles. Inherited child stdio
can carry the current parent TTY handle, so each `with_parent_*` configurator
initializes and caches the actual parent stream and spawn passes that exact
`uv_stream_t` through `UV_INHERIT_STREAM`. It does not fall back to raw
descriptor inheritance. Ordinary-file and TCP descriptors are not smuggled
into the process-stream records as `File` or `Connection` variants; unsupported
`uv_guess_handle` results fail explicitly.

Ownership, direction, generation, descriptor selection, buffered excess, and
the reader lock are ordinary private record metadata, not union variants.
The stable `os.stdin`, `os.stdout`, and `os.stderr` records lazily refresh
their cached pipe-or-TTY wrapper when the Runtime generation changes without
changing public object identity. Parent stdin also clears old excess and its
reader lock on that transition. Captured endpoints retain their process owner.
An inherited child descriptor still has no parent-facing endpoint in its
`Process` field, while merged captured output stores the exact same non-nil
`InputStream` record in both fields.

### D3. Graceful `os.exit`

Calling ISO C `exit` bypasses libuv cleanup, while `uv_stop` currently turns a
live Runtime into a fatal error. A graceful exit needs a distinct successful
exit-request state: request a status, cancel/settle other Tasks, run their
`finally`/`defer` cleanup, drain file/net/process/stdio owners (including the
existing TERM/grace/KILL child policy), close the loop, and make the outer
bootstrap return the requested status without reporting a fatal error.

The public contract is
`os.exit(code: integer?)`, defaulting to zero. It runs deferred cleanup, works
from the main Task or a child Task, and ultimately terminates a standalone
program through the normal generated entrypoint. It does not expose Lua's
`close` flag because a Titan module loaded into an embedding does not own the
Lua state. It does not accept Lua's boolean status and does not claim ownership
of an embedding Lua state.

### D4. `gc.pause` name collision

The conflict is not `gc.paused()`. That side-effect-free query remains exactly
as drafted. The draft declares `pause` twice:

- `gc.pause()` to stop collection; and
- the final brace-list
  `gc.{minormul,majorminor,minormajor,pause,stepmul,stepsize}(value: integer?): integer`,
  which expands to `gc.pause(value: integer?): integer` for Lua 5.5's
  incremental `pause` parameter.

Titan has no overloading, so preserve `pause()` as the action and name the
incremental tuning accessor `pause_percent(value: integer?): integer`.
`paused()` remains the side-effect-free running-state query.

### D5. Capture iteration and split edge semantics

`string.matches` returns match captures directly, but generic for stops when
its first visible result is nil. If an optional first capture is unmatched,
iteration ends even if this match has later captures or later matches exist.
That is precisely why `Regex:gmatch` currently returns a non-nil `RegexMatch`
record. `matches` documents this direct capture-tuple limitation; callers use
`gmatch` when the first capture can be optional.

Unless directed otherwise, `string.split` will use these deterministic rules:

- no delimiter yields one-byte strings and yields nothing for an empty input;
- a regex delimiter is not returned, even when it contains captures;
- leading, trailing, and adjacent delimiters produce empty fields;
- a zero-width delimiter advances by one byte after emitting the intervening
  field, using the same termination discipline as regex `gmatch`.

The `GroupSpan` refactor preserves the existing difference between an
unmatched capture and a participating empty capture. Store groups densely as
`Span`; reserve the impossible private span `(first=0,last=-1)` for unmatched,
while valid empty captures retain their actual position. Public accessors
translate only the sentinel back to nil.

### D6. `io.popen` lifecycle and result

The public method name and signal behavior are:

```titan
record InputOutputStream
  -- ReaderWriterCloser methods
  function wait(): os.ExitStatus
end

function popen(command: string): InputOutputStream
```

It spawns `/bin/sh -c command`, creates stdin plus one merged output pipe,
returns exactly one facade over that output, and makes `wait` idempotently reap
or return the stored status. `close` is idempotent: close stdin, request TERM
only while the child is still running, and wait/reap before it returns. A
signal-terminated child is represented by `os.ExitStatus`, rather than
collapsed into an invented integer exit code.

Each `SpawnOption` is an integer-returning configurator over an opaque public
`SpawnConfig`. `spawn` installs the three pipe defaults, applies supplied
configurators left to right, and stops on the first negative status. A
configurator performs and validates its real native setup immediately, caches
the initialized candidate so repeated use is idempotent, and may replace an
earlier selection without leaking or double-closing the now-inactive owner.
The public names are `with_stdin`, `with_stdout`, `with_stderr`,
`with_merged_output`, and the three `with_parent_*` alternatives. Later
options win.

### D7. Retire `os.communicate`

Maintainer decision: `io.popen` is the sole child-process convenience layer.
Remove the public `os.communicate` helper and its private four-Task
`HelperGroup` machinery. `os.spawn` continues to provide direct argv execution
and independently captured stdout/stderr for callers that need that control;
`io.popen` deliberately provides shell execution, one merged output stream,
and interactive duplex I/O. The retired one-call combination of whole-input
write, two separately buffered outputs, and final status is not preserved as a
second overlapping convenience API.

## Implementation workstreams

### Phase 1: documentation scaffold and public API fixtures

- Draft `doc/quick-tour.md` and `doc/style-guide.md` from the current language
  manual and existing stdlib. Use them to establish naming, error, ownership,
  iterator, async-yield, and FFI-boundary conventions for implementation
  workers; revise both again after code is complete.
- Write the final signatures selected in D1-D6 into the relevant language
  chapters and focused spec sources before filling in bodies.
- Keep new-module imports qualified and record the fourteen-root inventory.

### Phase 2: independent foundation modules

Run these in isolated worktrees/prefixes where practical.

#### `titan.math`

- Implement the approved numeric surface in `titan/math.titan` using `math.h`
  (`fabs`, trig functions, `atan2`, rounding, `fmod`, `frexp`, `ldexp`, logs,
  `sqrt`, `HUGE_VAL`) and Titan code for representation-independent helpers.
- Port Lua's xoshiro256** generator if compatible random semantics are chosen.
- Implement the approved lexical `tonumber` grammar without the Lua API.
- Add `spec/stdlib/math_spec.lua` for every function/constant, NaN/infinity,
  integer limits, tag policy, lexical grammar, deterministic seeds, unbiased
  range boundaries, and failures.

#### `titan.iter`

- Implement `next` through one audited Lua-stack operation, copying key/value
  roots before restoring the stack.
- Implement `pairs` with the correct iterator tuple and `ipairs` from index one
  through the Array's deterministic highest-present length, preserving inner
  nil values in the second result.
- Test arbitrary map keys/values, invalid continuation keys, empty maps,
  correct close slot, inner/trailing holes, and gradual `{value: value}` views.

#### `titan.gc`

- Implement `weak`/`ephemeron` by preserving or creating a metatable and
  setting only `__mode`.
- Implement the approved stop/restart names, status, collection, step, modes,
  exact byte count (`LUA_GCCOUNT * 1024 + LUA_GCCOUNTB`), and six parameter
  accessors through `lua_gc`.
- Restore collector mode/parameters in every spec teardown; cover weak values,
  ephemeron cycles, shared pre-existing metatables, mode changes, and parameter
  round trips under both incremental and generational collection.

These `iter`/`gc` operations and the later `lua` module are explicit audited
exceptions to the style guide's normal rule against application-level Lua API
FFI. Document stack effects, rooting, and longjmp assumptions in the
implementation manual.

### Phase 3: async/string streams and iterators

- Add `async.yield()` as the public facade over `uv._yield()`.
- Replace `GroupSpan` with dense `Span` storage and the approved private
  sentinel while preserving every current public regex result.
- Add `StringReader` with a cursor, binary-safe `read`/`read_until`, an
  idempotent terminal `close` that discards retained contents, and one
  scheduler yield on every read call including EOF.
- Add `StringWriter` with yielded writes, bounded chunk accumulation, a
  clearing `drain`, and no-op `close`; reuse/refactor the string builder rather
  than duplicating quadratic concatenation logic.
- Implement the approved `matches` and deterministic `split` contracts.
- Extend string/regex specs for empty versus unmatched spans, trailing
  unmatched captures, binary data, delimiter boundaries, EOF yielding,
  writer drain/reset, structural interface compatibility, all split boundary
  cases, and zero-width progress.

Once string imports async, isolated exact string specs must provide exact
coroutine/uv/async dependencies or use the canonical combined provider; do not
hide this dependency through checkout-local paths.

### Phase 4: fs and non-exit OS helpers

- Add `fs.lstat` with `uv_fs_lstat`, sharing `Stat` extraction while preserving
  `stat` symlink-following behavior.
- Add `fs.tmpname` using `uv_fs_mkstemp`, close the acquired descriptor, and
  return the still-existing unique path. Define cancellation cleanup so no
  descriptor leaks; follow the maintainer's decision on whether a successfully
  created path remains after cancellation.
- Add `fs.pwd`/`fs.chdir` through the existing libuv cwd/chdir machinery with
  fs-specific diagnostics; retain `os.cwd`/`os.chdir`.
- Add `fs.tmpdir` and `fs.homedir` as direct conveniences over the existing
  libuv `uv_os_tmpdir`/`uv_os_homedir` helpers.
- Add `os.clock` and current-time queries through portable libuv APIs; retain
  ISO C only for `difftime`, calendar conversion/formatting, `setlocale`, and
  the field form of `time`, where libuv has no equivalent. `time()`
  returns the current time; when any date field is supplied, require
  year/month/day and default hour=12, minute=0, second=0, DST unknown. Named
  parameters have no input table to normalize in place.
- Implement the approved typed result for `os.date`; support local/UTC (`!`),
  `*t`, default `%c`, and dynamically grown `strftime` output.
- Do not reimplement `os.getenv`; it already uses libuv and has coverage.
- Extend fs and OS helper specs with symlink contrast, tmpname uniqueness and
  cleanup, cwd restoration, UTC/local formatting, normalization, CPU time,
  locale query/set/restore, NUL rejection, and error diagnostics.

### Phase 5: generalized process/TTY streams and `titan.io`

- Refactor `titan/uv/process.titan` so stream controls carry read/write
  capability and an explicit owner/lifetime instead of
  `PIPE_STDIN`/`PIPE_STDOUT`/`PIPE_STDERR` kinds.
- Add owned per-generation pipe-or-TTY parent stream controls with lazy
  initialization. Register them in Runtime shutdown; never let a child close
  borrowed global stdio.
- Make spawn configuration functional and opaque. Each integer-returning
  configurator performs reusable setup/validation when called; `spawn` applies
  them in order and checks every status. Cache candidates for repeat/later-wins
  use, close inactive candidates, give merged stdout/stderr the same child
  `uv_stream_t` pointer, start one parent read, and expose the same high-level
  object in both Process fields.
- Add ordinary public `InputStream`/`OutputStream` records holding the opaque
  native stdio wrapper, with a private pipe/TTY handle union below them and
  `is_tty` dispatching only on that native kind. Stable `os.stdin`, `stdout`,
  and `stderr` records resolve their per-generation wrappers lazily.
- Implement graceful exit as the distinct successful Runtime transition
  approved in D3.
- Extend `titan/io.titan` beyond its seven interfaces:
  - `print(...: value)` renders left-to-right with `string.tostring`, joins with
    tabs plus one newline, and performs one write to `os.stdout`;
  - `lines(reader: ReaderCloser)` returns an iterator/state/initial/close tuple
    using `read_until("\\n", true)` and the idempotent `Closer` contract;
  - `popen` and `InputOutputStream` follow D6.
- Test PTY-backed stdio, captured pipes, rejection of unsupported stdio kinds,
  sequential Runtime generations, multiple borrowing children, inheritance choices,
  merged object identity and one-reader locking, configuration repetition,
  cancellation/GC/shutdown, print conversions, lines exhaustion/early exit,
  popen large duplex traffic, normal/signal exit, idempotent close/wait, and
  child reaping.
- Remove `os.communicate`, its low-level helper group, focused tests, metadata,
  and manual text in favor of the `spawn`/`popen` split fixed in D7.

### Phase 6: `titan.lua`

- `load`: save/restore the Lua stack, compile one binary-safe string with
  `luaL_loadbufferx`, raise load errors, apply the approved nil/global `_ENV`
  policy, root the resulting callable, and return it as
  `(...: value) -> (...: value)`.
- `load_from_reader`: iterate the Reader directly with
  `for chunk in reader:read`, append every returned string (including an empty
  chunk) to the bounded shared string writer, and leave reader ownership with
  the caller.
- `dofile`: open through `fs`, defer close across load/runtime errors, and
  forward flexible arguments/results.
- `require`: preserve `package.loaded`, preload, loader result/fallback-true,
  and diagnostics; search Lua source candidates with async `fs` instead of the
  blocking Lua file searcher. Preserve C searchers and allow generated Titan
  Lua shims naturally. Document the policy for custom/mutated searchers and
  concurrent requires selected during implementation review.
- Test syntax/runtime errors, embedded NULs, environment behavior, flexible
  values, reader protocol, close-on-error, preload/cache/fallback true,
  asynchronous Lua-source loading, C modules, Titan shims, and missing-module
  diagnostics.

### Phase 7: canonical provider, tests, and manuals

- Update fourteen-root/source/shim inventories and exact key/opener counts in
  `Makefile`, `scripts/stdlib_installer.lua`, the install/rollback specs,
  `spec/support/async_stdlib.lua`, `spec/support/ci_stdlib_snapshot.sh`,
  `spec/support/ci_libuv_mode_smoke.sh`, packaging specs, CI assertions, README,
  and multi-module library chapters.
- Update `spec/fixtures/stdlib/titan_stdlib_types.lua` for changed and new
  public interfaces. Revise the `spec/libuv_build_spec.lua` assertion that
  `titan/io.titan` contains interfaces only.
- Route all new `spec/stdlib/*_spec.lua` files to explicit non-LuaCov library
  shards in `spec/support/ci_test_groups.sh`.
- Language manual:
  - extend async, string, fs, os, and io chapters;
  - add standard-library math, Lua, iter, and GC chapters;
  - update the index and runnable cross-links.
- Implementation manual:
  - extend libuv runtime and string-library chapters;
  - add math internals, async Lua loading, and iter/GC stack-boundary chapters;
  - update provider counts, the FFI/Lua-API audit, and the index.
- Finish and cross-check `doc/quick-tour.md` and `doc/style-guide.md` against
  the implemented APIs and real Titan code. Link them from README and the
  language reading guide.
- Move `minimal standard library, continued` from README `Next` to
  `Supported` only after every item above is implemented and verified.

## Verification and delivery gates

1. Focused specs for each workstream in its isolated prefix/worktree.
2. Rebuild the canonical fourteen-root `titan.so`/`titan.a` pair and shims;
   prove exact ABI-0.20 metadata, DSO entries, archive keys, rollback, bundled
   and system-libuv production modes.
3. Run all explicit non-LuaCov library shards, then the full authoritative
   `make test` from a clean ambient policy (`ROCKS_TREE`, `TITAN_ROCKS_ROOT`,
   and `TITAN_EXTRA_CPPFLAGS` unset).
4. Run parallel adversarial reviews for API/requirements, async resource and
   GC lifetime, test coverage, and both manuals. Fix every actionable finding
   and repeat relevant gates.
5. Commit intentionally on `agent/stdlib-improvements`, push, and open/update
   the feature PR with final evidence.
6. Wait for exact-head Linux push CI to pass. Only after Linux and adversarial
   review are green, dispatch one exact-head macOS `ci.yml` run and require its
   complete suite to pass.

If any phase exposes a compiler/runtime rough edge rather than an ordinary
stdlib defect, stop at the minimal reproducer and ask the maintainer; do not
fix it or encode a library workaround on this branch.
