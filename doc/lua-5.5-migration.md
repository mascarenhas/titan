# Titan's migration from Lua 5.3 to Lua 5.5

This document explains every change made to migrate Titan from targeting
Lua 5.3.5 to targeting Lua 5.5.0 — both making the compiler's own Lua code
run on a Lua 5.5 host and making the generated C compile and behave
correctly against the `lua-5.5.0` source tree. The catalogue of underlying
Lua-internal differences is in
[lua-5.3-to-5.5-internals.md](lua-5.3-to-5.5-internals.md). After the
migration the full busted suite (803 tests, including the end-to-end coder
specs that compile and run real C) passes under Lua 5.5.

## Compiler host code (runs on Lua 5.5)

Lua 5.5 makes for-loop control variables read-only; assigning to one is
now a syntax error. Two loops did exactly that and were fixed by shadowing
the control variable with a regular local:

* `c-parser/cpp.lua` (`cpp.initial_processing`): `for line in fd:lines()`
  reassigned `line` when merging backslash-continued lines. The control
  variable was renamed `input_line` and `line` became a local. This error
  previously made `c-parser/cpp.lua` fail to even *load*, taking down
  `checker.lua`, `driver.lua` and `titanc` transitively.
* `titan-compiler/pretty.lua` (`reindent_c`): the gmatch control variable
  `line` was reassigned with its trimmed value; same shadowing fix.

Everything else in `titan-compiler/`, `c-parser/`, `typed.lua`, `titanc`
and `spec/` was audited against the official 5.3→5.4→5.5 incompatibility
lists and loads/runs unchanged on 5.5 (the pure specs passed before any
codegen work started).

## Runtime support library (`titan-runtime/`)

`titan.h`:

* `titan_pushmodule` now uses the 5.5 stack representation:
  `setclCvalue(L, s2v(L->top.p), c); L->top.p++;`.
* New `titan_setbvalue(obj,x)` macro replaces the removed `setbvalue`
  (5.5 booleans carry no payload; the macro picks `setbtvalue`/
  `setbfvalue`).
* `cast_func(t,p)` was renamed `titan_cast_func` because 5.5's
  `llimits.h` defines its own single-argument `cast_func`.
* `_float2str` was rewritten on top of `luaO_tostringbuff` (the
  `lua_number2str` macro no longer exists); `_integer2str` keeps
  `lua_integer2str`. Both now use `LUA_N2SBUFFSZ` (64) byte buffers
  instead of the old private 50-byte `MAXNUMBER2STR`, and the buffers are
  plain locals instead of `static` (the old `static` buffers were never
  thread-safe). **Behavior change:** float-to-string now matches the Lua
  5.5 host's `tostring` — `3.0` converts to `"3.0"` (not `"3"`), and
  values needing more than 14 significant digits keep full round-trip
  precision. This is documented in the manual and pinned by a spec.
* The `getgeneric` declaration was removed (see below).

`titan.c`:

* The verbatim copies of 5.3 `ltable.c` internals — the hash macros,
  `l_hashfloat`, `mainposition` and `getgeneric` — were **deleted**.
  They were unportable (5.5 node keys are not `TValue`s, the variant tag
  constants were renamed, booleans split into two tags) and unnecessary:
  generated code now calls the exported tag-returning `luaH_get` family
  directly for generic table lookups.
* `errorhandler` was restructured. It used to interleave `lua_push*`
  calls between `luaL_buffinit` and `luaL_pushresult`; 5.5's
  `luaL_Buffer` lives on the stack from `buffinit` on and must stay on
  top while in use, so the old ordering crashed inside `resizebox`
  whenever an error was raised (every runtime type-error path). All other
  pushes now happen before the buffer is started.
* `loadlib`/`loadsym` (public API only) are unchanged.

`titanlib.c` uses only the public API and needed no changes.

## Code generator (`titan-compiler/coder.lua`)

### Stack representation

All templates that touch the Lua stack were rewritten for
`StkId`/`s2v()`/`.p`:

* The function preamble reserves slots with `L->stack_last.p`,
  `L->ci->top.p`, declares `StkId _base = L->top.p`, and nils the
  reserved slice through `s2v`. `newslot` slots become
  `TValue *name = s2v(_base + depth)`, and returns restore `L->top.p`.
* `genluaentry` (the Lua-callable wrapper around each Titan function)
  declares `StkId func = L->ci->func.p`, reads arguments via
  `s2v(func + i)`, walks results with a `StkId _firstret` cursor writing
  through `s2v(_firstret)`, and saves `L->errfunc` in a `ptrdiff_t`
  (it was truncated to `int` before).
* The module `__index`/`__newindex` metamethods, record
  `__index_*`/`__newindex_*` metamethods, the module `init`/`luaopen`
  templates and `create_meta` all switched `L->top`/`L->ci->func`
  arithmetic to the union fields, with `setobj2s` for stack stores.

### Table access

* **Array reads** (`codeindexarray`) use 5.5's `luaH_fastgeti` macro into
  a local `TValue` holder, setting the holder to nil when
  `tagisempty(tag)` (5.5 getters leave the holder untouched on a miss).
* **Array writes** keep the old doubling-growth optimization but store
  through `obj2arr`/`luaH_resizearray`/`luaH_setint` instead of taking
  `TValue*` slots into `t->array` (impossible in 5.5). The index math is
  done in full-width `lua_Unsigned`, mirroring 5.5's own `luaH_fastseti`
  — see "Review findings" below.
* **Map reads** (`get_table_key`) dispatch per static key type to
  `luaH_getshortstr`/`luaH_getint`/`luaH_get` with the tag-returning
  calling convention; the `getgeneric` fallback and the
  `luaO_nilobject` pointer comparison are gone.
* **Map writes** were restructured from "find or create a slot, then
  `setobj2t`" (the `luaH_newkey` pattern, removed in 5.5) to "build the
  value into a local `TValue`, then `luaH_setint`/`luaH_set`", with
  `invalidateTMcache` after non-integer-key stores (generated code now
  includes `ltm.h` for this). Map-literal fills (`codemap`) and map
  assignment share this via a new `set_table_entry` helper. The explicit
  key barrier the old code emitted is no longer needed (5.5's insertion
  path barriers new keys internally); the value barrier remains the
  caller's job.
* `#` on arrays emits `luaH_getn(L, t)` (the function gained the
  `lua_State*` parameter).
* `luaV_tointeger(..., 0)` became `luaV_tointeger(..., F2Ieq)`.

### Values and type checks

* `getslot` for booleans reads `ttistrue(slot)`; `setslot` uses the new
  `titan_setbvalue`. Every `ttnov(x)` in error messages became
  `ttype(x)`; the short-string fast-path test became
  `ttypetag(k) == LUA_VSHRSTR`.

### Records

> **Superseded (0.7 ABI).** The CClosure+Udata dual object described below
> was the 5.5-migration-era representation. Records (and module state
> `_mod`) have since been collapsed to a **single Lua 5.5 `Udata`**: a
> record value *is* its userdata (fields in `uv[0..N-1]`, type identity in
> the udata's metatable, metatable on the udata), there is no backing
> closure, and field stores use the **back** barrier (`luaC_barrierback`)
> instead of the forward barrier. (As of the 0.8 ABI the record type
> identity is the metatable pointer — there is no raw tag payload in
> `getudatamem` at all.) See the
> [records/modules single-Udata plan](../.claude/plans/records-modules-udata-simplification.md)
> and the current [values and GC](implementation/values-and-gc.md)
> chapter; this section is retained as migration history.

Records are CClosures whose Lua-visible face is a Udata carrying a type
tag. The 5.5 Udata redesign forced:

* `luaS_newudata(L, sizeof(void*), 1)` — one user value, which now holds
  the back-reference to the CClosure as a real `TValue`
  (`setclCvalue(L, &_ud->uv[0].uv, closure)`), replacing the removed
  `_ud->user_.gc`/`_ud->ttuv_` raw-field pokes. The user value also makes
  the GC traverse the closure through the udata (a `nuvalue == 0` udata
  would hide it from the collector entirely).
* `checkandget` for nominal types reads the closure back with
  `clCvalue(&_ud->uv[0].uv)`.
* The closure is now anchored in its stack slot *before* `luaS_newudata`
  runs (the old code anchored it after, leaving a window where an
  emergency collection could free it), and the store of the udata into
  `upvalue[0]` is followed by a `luaC_barrier` (see "Review findings").

### GC write barriers

5.5's default generational collector turns missing barriers from a rare
incremental-mode race into reliable corruption, so the migration added the
barriers the old code skipped:

* forward `luaC_barrier` after storing collectable values into CClosure
  upvalues: record field assignment, record `__newindex`, module-variable
  assignment (own and imported modules' upvalues), module `__newindex`,
  and module-variable initialization;
* backward `luaC_barrierback(L, obj2gco(t), v)` for array/map stores —
  all existing table barriers also gained the `obj2gco` wrapper required
  by 5.5's `GCObject*`-typed `luaC_barrierback_`.

(Superseded in part by the 0.7 ABI: once records and `_mod` became
`Udata`, all of those record-field and module-slot stores flipped from
the forward barrier to the **back** barrier — a userdata's traversal
calls `genlink`, so the back barrier is the correct one. Only
function-value/closure upvalue stores still take the forward barrier.)

### Miscellanea

* The generated-code preamble gained `#include "ltm.h"`.
* The dynamic-import templates use `titan_cast_func`.

## Driver, CLI, specs, packaging

* `titan-compiler/driver.lua`: `LUA_SOURCE_PATH` defaults to
  `lua-5.5.0/src/`; `titanc --lua` help text updated. Everything else
  (cc invocation, linking, srlua-style entrypoint template) is
  public-API-only and unchanged.
* `spec/coder_spec.lua`: the `call()` helper runs the in-tree
  `lua-5.5.0/src/lua`; two regression specs were added (large array
  indices, float-to-string format — see below).
* `titan-dev-1.rockspec`: `lua ~> 5.3` → `lua ~> 5.5`.
* CI (`.github/workflows/ci.yml`): provisions Lua 5.5 via hererocks
  installed **from git master** — the PyPI hererocks release (0.25.1)
  does not know Lua 5.5 and would fail before running any test.
* `.gitignore` ignores the downloaded `lua-5.*` source trees;
  `README.md`, `CLAUDE.md` and `doc/manual.md` were updated (build
  instructions, paths, the float-formatting note, and the gotcha that the
  installed `titan` rock shadows the working tree under busted, so
  `luarocks make` must be re-run before testing compiler changes).

## Review findings (multi-agent audit of the migration diff)

The finished migration was reviewed by independent auditors over four
dimensions (GC/barriers, 5.5 API usage, semantic regressions vs the 5.3
codegen, host code/packaging), with every claim adversarially verified
against the real Lua sources — several with live reproductions — before
being accepted. Confirmed findings, all fixed:

1. **`errorhandler` crash** (critical, found while running the suite).
   Described above under `titan.c` — every runtime type-error path
   segfaulted in `resizebox` until the `luaL_Buffer` use was untangled.
2. **Array-write index truncation** (major). The write fast path kept
   5.3's `unsigned int _actual_i = l_castS2U(_k) - 1` while the migrated
   read path (`luaH_fastgeti`) computes the index in 64-bit width. For
   keys ≥ 2³² (or large negatives) whose truncated value landed inside
   the array part, the write clobbered the wrong element and the
   read-back missed it — reproduced empirically (`a[2^32+1] = v`
   silently overwrote `a[1]`). Fixed with full-width `lua_Unsigned`
   index math mirroring `luaH_fastseti` (including an overflow guard so
   `2*asize` cannot wrap `unsigned int` on pathologically large arrays),
   and pinned by the "array indices beyond the unsigned int range" spec.
3. **Missing barrier on the record-constructor Udata store** (major).
   `luaS_newudata` can trigger an emergency collection; under
   generational GC the survivors come out old+black, so the subsequent
   unbarriered `setuvalue` into the (now black) closure's `upvalue[0]`
   violated the generational invariant and could leave a dangling Udata.
   Fixed with a forward `luaC_barrier`, matching what `lapi.c` does for
   C-closure upvalue stores.
4. **Module-global array/map literals built unanchored** (critical,
   proven with an AddressSanitizer use-after-free reproduction).
   `codearray`/`codemap` had a fast path that, when the assignment
   target was a module global, used the `_mod` upvalue itself as the
   only anchor for the fresh table during the allocating fill loop.
   Minor collections do not rescan an old `_mod`'s upvalues without a
   barrier, so a `luaC_checkGC` inside any callee in the fill loop could
   sweep the half-built table. Fixed by always building container
   literals anchored in a real stack slot; the caller's existing
   store-plus-barrier publishes the finished object.
5. **Module-init stack slots sat above `L->top.p`** (critical,
   deterministic reproduction). The init prologue reserved slots with
   `lua_checkstack` but never raised `L->top.p`, so every toplevel-
   variable initializer anchored its intermediates in slots the
   collector neither marks nor preserves — 5.5's atomic step nils the
   dead slice above top on every collection (5.3 behaved the same; the
   generational default just makes it fire reliably). Fixed by raising
   and nil-filling the slice like ordinary function preambles do, and
   restoring `top` after the initializers run.
6. **Missing barrier on the module export-table store** (major). The
   init template stored the freshly created function table into
   `_mod->upvalue[0]` without a barrier; an emergency collection between
   the closure's creation and that store can blacken `_mod`. Fixed with
   a forward `luaC_barrier` (the same fix the migration had already
   applied to every other `_mod->upvalue` store).
7. **CI could not actually provision Lua 5.5** (major): PyPI hererocks
   (0.25.1) tops out at Lua 5.4.4; the workflow now installs hererocks
   from git master.
8. **Float-to-string format change** (minor, accepted as intentional):
   `_float2str` now matches Lua's own `tostring` (`.0` suffix, %.15g
   with %.17g round-trip retry) instead of 5.3-Titan's bare `%.14g`.
   Documented in the manual, pinned by a spec.
9. **`\u{...}` escape range silently widened** (minor). The lexer
   delegates to the host's `utf8.char`, which in 5.5 accepts codepoints
   up to 0x7FFFFFFF; Titan now enforces the Unicode limit (U+10FFFF)
   itself and reports `MalformedEscape_u` beyond it (this also turned
   the previously crashing empty `\u{}` into a proper lexer error).
   Pinned by lexer specs.

Claims that were investigated and *refuted* in verification:
`types.serialize` emitting the now-reserved word `global` as a bare table
key (it only emits quoted strings inside constructor calls), and the
rockspec dependency floors being broken on 5.5 (lpeglabel 1.5.0 is
source-compatible with 5.5 and the default resolution picks newer
versions anyway).

One pre-existing, unrelated issue surfaced during verification and was
left as-is: a record literal assigned directly to a module global fails
at compile time with an internal compiler error ("missing template
variable TMPNAME") — that path was unreachable before the migration and
remains so.
