# Lua 5.5.0 to 5.5.1 update audit

Titan compiles generated C against Lua's private headers and links the matching
`liblua.a`. A Lua point release therefore needs a source-level audit rather
than only a public-API compatibility check. This chapter records the complete
5.5.0 to 5.5.1 audit underlying a Titan ABI cutover.

## Scope and evidence

The primary source was Lua.org's
[official unified diff](https://www.lua.org/work/diffu-lua-5.5.0-lua-5.5.1.txt).
The exact audit input was its 3,773-line raw unified rendering, covering 39
changed files. Its SHA-256 is:

```
98a7137ac8533bc990a825c74ebbd8c26a04e698448d4d3ce8c76f7884ad12b5
```

This checksum identifies the raw text audited here, not the HTML presentation
of the diff. Every hunk was read, and every changed C identifier, macro,
internal structure, build setting, and documented C-API rule was searched
against Titan's compiler, runtime, standard library, vendored sources, tests,
and implementation documentation. The file table at the end accounts for all
39 upstream files.

The conclusions use three categories:

* **adapted** means Titan mirrors, parses, or otherwise depends on the changed
  construct and needed a repository change;
* **inherited** means the fix is inside the pinned Lua sources and reaches
  Titan by rebuilding, without a second Titan implementation;
* **no dependency** means Titan neither calls nor reproduces the changed
  private mechanism.

## Why this changes the Titan ABI

Lua 5.5.1 changes `LUAI_MAXALIGN` on the C99 configuration used by Titan from
fields based on `lua_Number`, `double`, `void *`, `lua_Integer`, and `long` to
`long double`, `void *`, and `long long`. Lua embeds that macro in the raw
userdata layout (`Udata0`) and in the public `luaL_Buffer` structure. The
change can alter alignment, offsets, or structure sizes for code built from
the private and auxiliary headers. Titan also directly compiles stack writes,
numeric operations, userdata access, GC barriers, and call machinery against
those headers.

Consequently, a provider compiled with the 5.5.0 internal-header set must not
be combined with the 5.5.1 runtime or generated code, even on a target where a
particular layout happens to have the same numeric size. Titan therefore:

* identifies the generated-code contract with the active
  `TITAN_ABI_VERSION` marker;
* publishes the standard pair under the independently derived
  `TITAN_VERSION` major/minor directory `lib/titan/<library-version>/` and uses
  `TITAN_PATH_<major>_<minor>` for the versioned search override;
* stages and discovers `src/lua-5.5.1` together with its matching
  `liblua.a`; and
* rejects providers, archives, generated interfaces, and compiler SDK objects
  whose embedded ABI does not match the active marker.

This is an exact-header compatibility boundary, not a claim that Lua changed
one of Titan's language-level value representations.

## Required Titan adaptations

### Source, build, and installation identity

`Makefile`, `titan-compiler/driver.lua`, the C preprocessor driver, fixtures,
and installed-layout tests now select `lua-5.5.1`. Both native build paths
consume the same Titan Lua fork pinned by the `lua-5.5.1` Git submodule
without applying patches or rewriting source. Platform guards select its
POSIX and Windows implementations during compilation. Linux uses upstream's new
`linux-readline` target, while macOS keeps upstream's `macosx` target, whose
5.5.1 `luaconf.h` now enables readline itself. Before either build, Titan
compile-links a host Readline probe. When development files are absent, it
downloads the checksum-pinned GNU Readline 8.3 base archive and applies the
exact vendored `vendor/readline/readline-8.3-p1-p3.patch`, a format-only
combination of official patches 001-003. It configures the patched source with
the same installation prefix and native tool identities, installs the whole
dependency under a private prefix-local directory, and records that provider
plus its detected terminal-capability link input in Lua's content stamp. The
combined patch and checked-in license have their own verified hashes in that
stamp. A fallback build installs into a sibling stage, validates the headers,
license, archive, and exact final link, and only then replaces the private
root; a failed repair therefore leaves the last known-good installation in
place. `READLINE_HOST` provides an explicit Autoconf cross-target triplet, and
the effective compiler, preprocessor, linker, archiver, and terminal inputs
all participate in invalidation. Thus an immutable host does not need
`libreadline-dev`/`readline-devel`, while hosts that provide a usable
development library continue to use it.

Upstream inserted whitespace between `LUA_CDIR` and its string literal in
`LUA_CPATH_DEFAULT`. Titan's `luaconf.h` rewrite now accepts either spacing,
inserts `LUA_TITAN_CDIR "?.so;"` exactly once, and verifies that exact-one
postcondition before accepting the configured header.

### Stack-slot writes

Lua 5.5.1 adds the stack-aware helper
`setnilvalue2s(stk)` and adopts it for affected direct stack-slot writes in
the interpreter. Generated Titan C followed the same distinction at all of
its stack-slot initialization and cleanup sites: function, initializer and
lambda frames; interface adapters; result runs; fixed-call nil filling;
flexible-call storage; vararg/flexible cleanup; and module initialization.
Ordinary non-stack `TValue *` stores continue to use `setnilvalue`.

### Floating numeric `for`

The 5.5.1 `luai_numadd`, `luai_numsub`, `luai_nummul`, and `luai_numunm`
defaults all evaluate their `L` argument. Lua correspondingly passes `L` into
its floating-for helper and advances through `luai_numadd`. Titan's generated
floating numeric-for loop now advances with
`luai_numadd(L, _foridx, _forstep)` instead of raw `+=`. This preserves the
configured Lua numeric-operation hook contract as well as matching upstream's
new required call shape.

### Native packing alignment

`titan.string` implements Lua's `string.pack` format, including the omitted
argument to `!`, which means the target's native `LUAI_MAXALIGN`. The old
mirror computed the maximum alignment of the old macro's fields. Titan
exports an FFI spelling for `long double` and now computes the maximum of
`long double`, `void *`, and `long long`, matching Lua 5.5.1. The string suite
compares a format whose result distinguishes an 8-byte cap from a 16-byte cap
on targets where those alignments differ.

### Metatable publication

The revised manual warns that conditional initialization through
`luaL_newmetatable` publishes a newly created, minimally initialized registry
entry before later caller-side allocating initialization. (`luaL_newmetatable`
itself has already installed `__name`.) If that later initialization raises,
retrying sees the entry and can skip the missing work. Lua fixes its
auxiliary-library UBox metatable by building the table first and publishing it
last.

Titan applied the same rule to every production site that formerly used the
unsafe conditional pattern:

* the shared Array proxy metatable in `titan-runtime/titan.c`;
* the private coroutine-owner metatable in `titan/coroutine.titan`; and
* generated owned-C metatables in `titan-compiler/coder.lua`.

Each site now handles an absent entry by constructing and initializing an
off-registry table, publishes it only after allocating steps succeed, and
rejects a pre-existing non-table entry. The replacement paths also preserve
their public `__name` fields, which the focused runtime tests inspect.
Generated record, union, Interface, and module metatables do not condition
their initialization on
`luaL_newmetatable`'s return value and therefore did not have this particular
conditional skip-on-retry pattern. Generated module initialization has a
separate, older early-publication contract for its module userdata; this
point-release audit does not claim that arbitrary module initialization is
transactional or retryable.

## Copied and reimplemented behavior audit

### Lua longjmp boundary

`titan-runtime/titan.h` vendors the `lua_longjmp` definition and the
setjmp-selection contract from `ldo.c`. The audited source range, 5.5.1
`ldo.c` lines 61-109, is unchanged from 5.5.0. Only the provenance annotation
needed to advance to 5.5.1; the vendored definition and selector did not
change.

### String library translations

The source-derived `titan.string` code was compared against every `lstrlib.c`
hunk:

* `string.rep` now immediately returns for an empty subject and empty
  separator, matching upstream and avoiding unnecessary size arithmetic;
* `string.packsize` now checks against Lua's `MAX_SIZE`; Titan already computes
  the same target limit as the smaller of `SIZE_MAX` and `LUA_MAXINTEGER`, so
  no second change was needed there;
* the `LUAI_MAXALIGN` mirror required the packing change described above; and
* Lua pattern `MatchState` and `gsub` changes do not map to Titan's PEG-backed
  regex implementation.

The changed portions of `lstrlib.c` do not require changes to Titan's
source-derived formatting code, mathematical library, or OS library.

### UTF-8 decoding in private LPegLabel

Lua's UTF-8 library now rejects lead bytes at or above `0xFE` before a loop
that would otherwise read too many continuation bytes and perform an oversized
shift. Titan does not copy that decoder into the compiler, but the private
LPegLabel engine had the same loop shape. Its decoder permits at most the
standard four-byte Unicode range, so it now rejects at `0xF8`: five-byte and
longer sequences are impossible for that implementation. The stricter bound
is deliberate and is recorded in `vendor/lpeglabel/UPSTREAM.md`.

### Parser, loader, GC, table, and VM changes

The remaining close analogues were checked explicitly:

* Lua moves `leaveblock` in `repeat` compilation. Titan already checks and
  emits the `until` expression inside the body scope, including defer cleanup,
  and does not emit Lua bytecode.
* `lua_load` performs a GC check before parsing and the parser/undumper share a
  new anchor table. `titan.lua.load` calls `luaL_loadbufferx`; its source,
  chunk name, environment, result, and failure values follow Titan's existing
  caller/local stack-root discipline. Titan does not call `luaY_parser`,
  `luaU_undump`, `luaD_anchorobj`, or the removed `luaD_inctop`.
* `lua_gc(L, LUA_GCSTEP, size)` avoids debt subtraction overflow. `titan.gc`
  passes a checked non-negative `size_t`, so it inherits the corrected Lua
  implementation without reproducing the debt calculation.
* Titan's Array stores and fresh-Map constructor stores call `luaH_set` or
  `luaH_setint`; Map assignment keeps those calls as its
  no-metatable/no-`__newindex` fast path. When `__newindex` may exist, Map
  assignment uses `luaH_fastseti` or `luaH_pset` before delegating an unresolved
  location to `luaV_finishset`. All of these paths inherit `ltable.c`'s
  normalized-float-key fix. Titan does not call the private `luaH_newkey`
  implementation or `luaH_psetint`.
* Titan uses `gco2u`, `obj2gco`, and CallInfo fields, but the 5.5.1
  GC-object conversion macros retain their names and type meanings, and the
  CallInfo result encoding used by flexible calls is unchanged. Recompilation
  against the matched headers is sufficient.
* `luaV_finishset` now saves the table identity across a possibly relocating
  `__newindex` lookup. Generated Titan Map assignment delegates its unresolved
  partial-set case to that VM helper and restores `_base` afterward, rather
  than copying the metamethod loop; public Lua writes use the same fixed helper.

### Public header parsing

`lauxlib.h` parenthesizes the declarator names `luaL_alloc` and
`luaL_makeseed` without changing their types. Titan's C declarator machinery
already accepts parenthesized declarators. Importing the complete 5.5.1 Lua
headers through the normal C-driver tests is the regression gate; no grammar
special case was added.

## Complete upstream file disposition

| Upstream file | Change and Titan disposition |
| --- | --- |
| `Makefile` | Adds `linux-readline` to the platform list and advances the release number. **Adapted** in Titan's version and platform selection. |
| `README` | Advances release identity and date. **Adapted** in Titan's installation documentation; no code dependency. |
| `doc/contents.html` | Copyright, date, and revision metadata. **No dependency.** |
| `doc/manual.css` | Adds wrapping behavior for API declarations. **No dependency.** |
| `doc/manual.html` | API formatting plus clarified string-pointer, userdata-alignment, stack-effect, debug, grammar, and metatable-initialization rules. **Audited**; alignment and metatable rules required the changes above. |
| `doc/readme.html` | Release directory, feature-list, copyright, and date updates. **No implementation dependency.** |
| `src/Makefile` | Adds `linux-readline`; moves the macOS readline define into `luaconf.h`. **Adapted** in Titan's build target and prerequisites. |
| `src/lapi.c` | Stack-aware nil stores, pre-load GC check, safe GC-step debt arithmetic, and stricter debug checks. Stack stores were **adapted**; load and GC fixes are **inherited**. |
| `src/lauxlib.c` | Safe UBox metatable publication and text-only `luaL_loadstring`. Metatable construction was **adapted**; Titan uses `luaL_loadbufferx`, not `luaL_loadstring`. |
| `src/lauxlib.h` | Parenthesizes two function names in declarators. Existing C declarator support is sufficient; covered by header-import tests. |
| `src/lbaselib.c` | Loader mode defaults and generic-reader anchoring move into the loader protocol. **Inherited**; Titan's reader facade buffers before loading. |
| `src/lcode.c` | Nil constant anchoring and safe temporary assignments in Lua bytecode generation. **No dependency.** |
| `src/ldblib.c` | Debug command input is explicitly text-only. **No dependency.** |
| `src/ldebug.c` | Stack-aware nil store and `OP_GETVARG` name recovery. **Inherited** by Titan's public debug-info traceback walk. |
| `src/ldo.c` | Minimum-stack/CallInfo preparation, parser anchoring, removed `luaD_inctop`, and stack-aware nil stores. Titan's direct `luaD_callnoyield` use is unchanged; the rest is **inherited** or unused. |
| `src/ldo.h` | Replaces the `luaD_inctop` declaration with `luaD_anchorobj`. **No Titan references.** |
| `src/lgc.c` | Stack-aware nil store and pending-finalizer guard. **Inherited.** |
| `src/llex.c` | Tests numeric `LUA_COMPAT_GLOBAL`. **No dependency.** |
| `src/llimits.h` | Numeric-operation defaults consume `L`. Floating-for advancement was **adapted**. |
| `src/loadlib.c` | Source-module loads use explicit binary/text mode. **Inherited**; the Titan fork's POSIX `setprogdir` changes executable-relative search paths only. Its Windows loader remains stock; Titan's provider directories are configured in `LUA_CPATH_DEFAULT`. |
| `src/lobject.h` | Adds `setnilvalue2s`. Generated stack writes were **adapted**. |
| `src/lopcodes.c` | Corrects top-use bookkeeping for `OP_VARARGPREP`. **No dependency** because Titan does not emit or inspect Lua bytecode. |
| `src/lopcodes.h` | Makes `luaP_isOT` a test macro and revises opcode-mode descriptions. **No Titan references.** |
| `src/lparser.c` | Shared anchor table, warning cleanup, repeat close ordering, and numeric compatibility guard. Titan's repeat scope was already equivalent; other changes are **inherited** by the host Lua compiler. |
| `src/lparser.h` | Adds the anchor argument to `luaY_parser`. **No Titan references.** |
| `src/lstate.c` | Makes `luaE_extendCI` optionally non-throwing and uses stack-aware nil stores. **Inherited.** |
| `src/lstate.h` | Rewrites GC-object conversions as checked direct casts and changes `luaE_extendCI`'s signature. Existing `gco2u`/`obj2gco` uses remain valid; matched-header recompilation is required. |
| `src/lstrlib.c` | Empty-repeat fast path, per-match depth reset, boolean `gsub` update, and `MAX_SIZE` pack-size bound. Source-derived behavior was audited and adapted where required. |
| `src/ltable.c` | Preserves the normalized integral key used for a float-key insertion. Titan's raw stores **inherit** the fix. |
| `src/ltablib.c` | Strings need no `__len`; `table.unpack` validates readable table-like input even with an explicit end. **Inherited**; Array proxies still provide all required callbacks. |
| `src/ltm.c` | Stack-aware nil stores. No additional Titan adaptation beyond the generated-code stack audit. |
| `src/ltm.h` | Removes an obsolete table-flag comment. **No dependency.** |
| `src/lua.c` | Explicit load modes, `-E` environment indirection, configurable readline loading, and optional debug-library startup. Interpreter-CLI behavior is **inherited**; no generated-code dependency. |
| `src/lua.h` | Advances release number and copyright. **Inherited** through the pinned public headers. |
| `src/luaconf.h` | Readline policy, path-token spacing, numeric compatibility macro, compiler guard, and `LUAI_MAXALIGN`. Path rewriting and native alignment were **adapted**; this file is central to the Titan ABI. |
| `src/lundump.c` | Uses the shared parser anchor table. **No direct Titan dependency.** |
| `src/lundump.h` | Adds the anchor argument to `luaU_undump`. **No Titan references.** |
| `src/lutf8lib.c` | Rejects impossible high lead bytes before excess reads/shifts and corrects an unsigned formatting cast. Lua behavior is **inherited**; the analogous private LPegLabel decoder was adapted. |
| `src/lvm.c` | Passes `L` to float-loop arithmetic, uses stack-aware nil stores, and preserves table identity through `__newindex`. Floating-for code was **adapted**; VM behavior is otherwise **inherited**. |

## Upgrade gate

The audit is complete only together with the ordinary repository gates: pure
compiler/C-parser tests against the new headers, generated-C and standard
library behavior tests, packaging/layout tests for the active ABI and library
version, the full local
suite, Linux CI, and the manually dispatched complete macOS suite. Those tests
verify the implementation identified by this audit; they do not replace the
source comparison itself.
