# FFI wrapup: stdlib shim-removal and function-like macro research

Status: research only. This document does not modify the draft plan or propose compatibility machinery for an old installation.

## Recommendation

1. **Use explicit `static inline lmacro_*` accessors for this wrapup.** Add narrowly typed wrappers for Lua's `thvalue`, `uvalue`, `clCvalue`, and `pvalue` macros, plus one typed helper that pushes a raw `Udata *` onto the Lua stack. The host C preprocessor still expands the real Lua macros in each inline body; Titan only sees ordinary, typed C functions. This needs no function-macro type inference, no new callable category, and no new probe path.
2. **Do not add generic function-like macro exposure to the same change.** The preprocessor already retains enough metadata to recognize a function macro, but a replacement list is not a callable prototype. Arity alone does not provide parameter types, result type, addressability, evaluation count, or a way to type a polymorphic macro. Direct support is sound only with an explicit trusted signature contract and a declaration-only macro-call category distinct from `Type.CFunction`.
3. **Remove the callback trampolines, not all of `titan_coro.c`.** `titan_uv.c` and `titan/http/native/titan_httpshim.{c,h}` can disappear. `titan_coro.c` cannot: it is the one `MINICORO_IMPL` translation unit and also supplies the immutable Lua-value tag comparator selected by `MCO_TAG_COMPARATOR`. Reduce it to those two responsibilities, make the comparator translation-unit-local, remove only `titan_coro_entry`, and delete `titan/coro.h`.
4. **Preserve the existing callback protocols mechanically.** In particular, stack-root the callback **owner**, not merely the module closure upvalue, and keep the filesystem callback's current no-extra-result shape. The example in `ffi-wrapup.md` pushes `callback.upvalue[0]` and passes an extra filesystem result; neither matches the current reviewed boundary.
5. **Bump the compiled-module ABI if the old native symbols are actually removed.** The existing ABI made the promoted `titan_uvshim_*` callbacks part of the runtime/provider native-symbol contract. Removing those symbols (and `titan_coro_entry`) is the inverse boundary. Follow Titan's clean-start prototype policy rather than retaining compatibility wrappers or deleting old-version installations.

The `lmacro_` choice is intentionally scoped to the trusted, pinned Lua 5.5.1 headers used by Titan's own standard library. It is not a claim that arbitrary third-party function macros are ordinary C functions.

## Research evidence

I inspected the current C sources, headers, all Titan call sites, Make and source-rock wiring, compiler macro pipeline, probes, and the structural/packaging specs. I also made two throwaway headers under `/tmp` (nothing tracked):

* Typed `static inline` wrappers for the four Lua accessors, and a raw-`Udata` push helper, were accepted by the current `cdriver.process_file` and compiled as C99 with `cc`, GCC, and Clang using the configured Lua 5.5.1 internals.
* Parenthesized same-spelling declarations such as
  `extern CClosure *(clCvalue)(const TValue *);` were also parsed by `cdriver`, while a C call `clCvalue(value)` was expanded by the host preprocessor. This proves a viable future explicit-signature/direct-emission mechanism; it does **not** make unannotated upstream macros safely inferable.

A header containing only `lobject.h` was insufficient for inline accessor bodies: expanded `thvalue`, `uvalue`, and `clCvalue` depend on `gco2*` definitions from `lstate.h`. A self-contained Titan-owned wrapper header therefore has to include `lstate.h` (or rely on a fragile include-order precondition). `titan/ffi.h` is already an internal-runtime FFI boundary and the draft names it as the home, so including `lstate.h` there is the smallest supported arrangement. A separate `titan/lmacro.h` is possible if maintainers prefer to avoid enlarging every `titan/ffi.h` import, but it adds another SDK header without changing the semantics.

The draft spells one wrapper `lmacro_clCValue`; Lua's actual macro is `clCvalue`, so the consistent wrapper spelling should be `lmacro_clCvalue`.

## Current shim inventory

There are 22 distinct plain-C callback entries and 37 Titan references to them.

| Boundary | C source / header | Distinct callbacks | Titan references | Current physical owner | Recommended disposition |
|---|---|---:|---:|---|---|
| coroutine | `titan-runtime/titan_coro.c`, `titan-runtime/titan/coro.h` | 1 entry trampoline | 1 | `titan_coro.o` in `libtitan.a` | Move entry to `titan/coroutine.titan`; retain reduced `titan_coro.c` and `titan_coro.o`; delete `coro.h` |
| libuv | `titan-runtime/titan_uv.c`, `titan-runtime/titan/uv.h` | 13 | 28 | `titan_uv.o` in `libtitan.a` | Move callbacks to the owning `titan.uv` contributors; delete `titan_uv.c`/`.o`; retain and narrow `uv.h` because it still defines two non-callback FFI storage types |
| llhttp | `titan/http/native/titan_httpshim.c`, `.h` | 8 | 8 | separate metadata-free `-X` object, later flattened into standard `titan.a` | Move callbacks to `titan/http/native.titan`; delete source, header, object, flags, and payload wiring |

### Coroutine

`titan_coro_entry` is selected once at `titan/coroutine.titan:260`. It recovers this exact owner prefix:

* `uv[0]`: Lua thread (`thvalue`),
* `uv[1]`: module userdata (`uvalue`),
* `uv[2]`: `coro_entry` closure (`clCvalue`),
* `uv[3]`: user callback `TValue`.

It reads the closure's native pointer from upvalue 2 and invokes the Titan native entry as `(T, M, NULL, f, co)`. A foreign replacement should preserve `_fn == NULL`; this callback is not the captured closure protocol used by the libuv/HTTP continuations.

The same C file is not merely a shim file. It defines `MINICORO_IMPL`, so all `mco_*` implementation symbols come from `titan_coro.o`. It also compiles minicoro with:

```c
#define MCO_TAG_COMPARATOR titan_coro_tag_equal
```

That fixed comparator calls `luaV_equalobj` on the two `TValue *` tags. Falling back to `mco_set_tag_comparator` is not equivalent: without `MCO_TAG_COMPARATOR`, minicoro stores its comparator in a mutable translation-unit static. That would violate Titan's multi-state rule that semantic state live in traced Lua/per-runtime state, not shared C globals. A per-`mco_runtime` comparator redesign could move it later, but it changes vendored minicoro layout/API and is not needed to remove the entry trampoline.

The minimal reduction is therefore:

* predeclare a `static` tag comparator in `titan_coro.c` before including `MINICORO_IMPL`;
* keep the fixed `MCO_TAG_COMPARATOR` and minicoro configuration;
* delete the exported `titan_coro_entry` and its callback typedef;
* assign the generated foreign coroutine entry directly to `mco_desc.func`;
* delete the now-unused `titan/coro.h` import/header.

### Libuv

The 13 symbols and their 28 references are:

| Callback | References | Owning source(s) |
|---|---:|---|
| `titan_uvshim_signal_cb` | 1 | `titan/uv/os.titan` |
| `titan_uvshim_process_exit_cb` | 1 | `titan/uv/process.titan` |
| `titan_uvshim_getaddrinfo_cb` | 1 | `titan/uv/tcp.titan` |
| `titan_uvshim_connect_cb` | 1 | `titan/uv/tcp.titan` |
| `titan_uvshim_write_cb` | 1 | `titan/uv/runtime.titan` |
| `titan_uvshim_shutdown_cb` | 1 | `titan/uv/tcp.titan` |
| `titan_uvshim_alloc_cb` | 2 | process stdio and TCP |
| `titan_uvshim_read_cb` | 2 | process stdio and TCP |
| `titan_uvshim_connection_cb` | 1 | `titan/uv/tcp.titan` |
| `titan_uvshim_close_cb` | 1 | `titan/uv/runtime.titan` |
| `titan_uvshim_walk_cb` | 2 | two runtime shutdown walks |
| `titan_uvshim_timer_cb` | 1 | `titan/uv/task.titan` |
| `titan_uvshim_fs_cb` | 13 | all asynchronous filesystem submissions in `file.titan` |

Each current trampoline obtains a strongly rooted owner from libuv data, selects callback slot 1, 2, or 3, recovers `CClosure *`, module upvalue 0, and native pointer upvalue 2, saves the main stack top, pushes the owner, invokes an exact Titan native entry with `_fn == callback`, and restores the top. Callback-specific behavior is deliberately narrow:

* signal: one integer;
* process exit: two integers;
* DNS: status plus result pointer;
* connect/write/shutdown/connection: one integer;
* alloc: size plus `uv_buf_t *`;
* read: `nread` only (the libuv `buf` argument is intentionally ignored);
* timer/close/fs: owner only;
* walk: handle pointer.

The filesystem draft example should not eagerly call `uv_fs_get_result` and widen the stored closure. Today `uv_fs_t.callback` is `(uv_fs_t) -> ()`, and the closure itself reads the result before `complete_fs`. Keeping that split makes shim removal mechanical and avoids an unrelated continuation-layout change.

Place each foreign callback beside its semantic owner (`file.titan`, `os.titan`, `process.titan`, `runtime.titan`, `task.titan`, or `tcp.titan`) rather than building a new central forwarding layer in `uv.titan`. Folder contributors are one logical module/translation unit, so shared FFI imports and local foreign-entry type aliases remain module-wide.

`titan-runtime/titan/uv.h` cannot simply be deleted. Besides callback prototypes and slot constants, it owns:

* `titan_uvshim_address`, the aligned 256-byte opaque address cell used by TCP DNS results;
* `titan_uvshim_char_ptr`, used for owned argv vectors.

Remove the callback declarations and rewrite the comments. Keep the storage types for now. Renaming their historical `shim` prefix during the same ABI bump is optional nomenclature cleanup, not required for callback removal and would touch otherwise unrelated code/docs. Named slot constants may remain, preferably renamed away from `SHIM`, if they are useful to the generated foreign bodies; otherwise use reviewed literal indices and keep the record-prefix structural tests.

### HTTP/llhttp

`titan_httpshim.c` defines four data callbacks and four no-data callbacks. They select `Parser` owner slots 3 through 10; slot 2 holds the active `lua_State *`. Each callback recovers module/closure/entry, saves the stack top, pushes the owner, invokes an exact Titan entry returning C `int`, restores the stack, and returns the result.

All eight settings assignments are in `titan/http/native.titan:199-209`, so this migration is contained in that contributor. Define the eight foreign functions there, point `llhttp_settings_t` fields directly at them, and delete the `titan_httpshim.h` foreign import. Preserve the exact callback shapes and synchronous return path.

The first eleven `Parser` fields are a raw callback ABI within this generated module. Foreign bodies cannot read ordinary Titan constants, so either use literal indices with one audited comment/test or retain C enum constants in a narrow support header. Retaining a header only for eight indices is more machinery than the literals; the raw layout is already tested and private.

### Rooting and stack restoration: final review correction

The retired libuv and HTTP bridges called `titan_pushmodule(L, owner)`. Despite
its historical name, that macro pushed the supplied `Udata *`, so the initial
migration reproduced it with a typed `titan_ffi_pushudata` helper. Final review
established that this was redundant: every libuv owner remains reachable through
its traced runtime owner set or callback/task ownership chain, and each llhttp
callback is synchronous while its Parser owner remains traced. The raw pointer
is therefore backed by an existing GC path throughout every callback.

The final implementation has no push helper and does not create a duplicate
stack root. It still saves and restores the Lua top because the invoked Titan
entry may use the stack. This correction does not introduce a registry lookup or
runtime-global root.

## Build, SDK, and source-rock wiring

### Runtime archive

Current Make/driver/install contracts encode exactly three runtime members:

```text
titan.o
titan_coro.o
titan_uv.o
```

The following all need to become the exact two-member contract `titan.o`, `titan_coro.o` after libuv callback migration:

* `Makefile`: `UV_O`, `TITAN_RUNTIME_OBJECTS`, the `$(UV_O)` compile rule, `UV_CONFIG_STAMP`, and `$(TITAN_RUNTIME_LIB)` member stamp;
* `runtime: libuv ...`: runtime itself can stop depending on libuv (the full `titan`/stdlib target still needs libuv and must keep it);
* `titan-compiler/driver.lua`: `RUNTIME_ARCHIVE_INPUTS`, `RUNTIME_ARCHIVE_MEMBERS`, lazy checkout-runtime freshness, and exact archive validation;
* `spec/driver_spec.lua`, `spec/libuv_build_spec.lua`, `spec/rockspec_spec.lua`, and the negative non-membership check in `spec/lpeglabel_build_spec.lua`;
* README, language modules/static-provider docs, implementation driver/index docs, and `AGENTS.md` exact-member statements.

Remove `titan_uv.c` and `titan/uv.h` callback-source prerequisites from the lazy runtime input list, but retain `titan/uv.h` in SDK inputs while its storage typedefs remain.

`titan_coro.o` remains. Its rule should depend on `titan_coro.c`, `minicoro.h`, the Lua internal headers/configuration, and any actual generic FFI header it uses, but no longer on deleted `titan/coro.h`. Remove `titan/coro.h` from `TITAN_SDK_NAMESPACED_HEADERS`, driver freshness inputs, and installed-header assertions.

`UV_CONFIG_STAMP` is used only to rebuild `titan_uv.o` and is otherwise only cleaned. Delete it rather than leaving a dead libuv-policy stamp; the bundled/system dependency and stdlib payload already have their own configuration identities.

### HTTP payload

The HTTP shim is **not a member of** `libtitan-llhttp.a`. That private archive already contains exactly `llhttp.o`, `http.o`, and `api.o`. `llhttp-build/titan_httpshim.o` is a separate `-X` item immediately before the llhttp archive, and library publication later flattens both into the combined `titan.a`.

Remove:

* `TITAN_HTTPSHIM_SOURCE`, `_HEADER`, `_O`, `_CPPFLAGS`, and `_RUNTIME_CPPFLAGS`;
* the shim object prerequisite from `llhttp`;
* shim/Lua-runtime inputs and checksums from `LLHTTP_BUILD_CONFIG`;
* the shim compile rule;
* the object from `STDLIB_EXTRA_OBJECTS` and `STDLIB_NATIVE_IDENTITY_PREREQS`;
* the shim include directory from `STDLIB_HTTP_CPPFLAGS` (leaving `LLHTTP_CPPFLAGS`);
* dry-run fixture overrides and expected bundled/system `-X` payload strings in `spec/libuv_build_spec.lua`.

Keep the exact three-member llhttp archive and its normal tool/configuration validation. The active rockspec delegates its build to Make and has no separate object list, but `spec/rockspec_spec.lua` explicitly expects `titan_httpshim.{c,h}` in the source rock; remove those entries. Its assertion that the private header is not installed becomes obsolete once the source is deleted.

### Generated foreign headers and payload identity

The converted callbacks live in their generated logical module objects and therefore naturally travel in `titan.so`/`titan.a`; they must not be repeated as metadata-free `-X` payload. The standard-library configuration/completion stamp already hashes generated-source/compiler inputs and `STDLIB_EXTRA_OBJECTS`; after removing the explicit object, keep the normal source/header-generation dependencies so changes to a foreign callback rebuild the owning generated module and provider pair.

Do not install a child callback archive or preserve old callback symbols through a compatibility object. A stale prior-ABI prefix is outside this prototype transition; validate from a fresh isolated prefix.

## Function-like C macros

### What exists now

The C preprocessor already parses and expands function-like definitions, including variadics, stringification, token pasting, spacing, recursion suppression, and redefinitions. `cdriver.process_file` already returns `macro_definitions` and `macro_changes`, and `symtab.apply_foreign_macro_changes` reconstructs the final cumulative macro environment matching generated C's hoisted include block.

The deliberate gap is publication into the FFI namespace:

* `cdefines.register_defines` skips a function macro because its descriptor has no array replacement tokens at the top level (`#def == 0`); only object-like expressions/aliases/field projections are registered.
* `lobject.h` gives `clCvalue`, `uvalue`, `pvalue`, and `thvalue` replacement lists but no callable C declarations.
* `foreigntypes` therefore has no parameter/result declaration to convert, and the checker/coder cannot soundly treat the name as `Type.CFunction`.

A configured-compiler compile probe can answer whether one concrete expression is accepted. It cannot portably recover a general C99 result type or invent the parameter types needed before Titan checks a call. Parsing the replacement expression in Titan would recreate compiler semantics and contradict the draft's correct requirement that the host preprocessor perform expansion.

### Option A: typed inline `lmacro_*` wrappers (recommended now)

A Titan-owned header provides ordinary monomorphic declarations and inline definitions:

```c
static inline lua_State *lmacro_thvalue(const TValue *o) { return thvalue(o); }
static inline Udata *lmacro_uvalue(const TValue *o) { return uvalue(o); }
static inline CClosure *lmacro_clCvalue(const TValue *o) { return clCvalue(o); }
static inline void *lmacro_pvalue(const TValue *o) { return pvalue(o); }
```

Properties:

* the pinned host header remains authoritative for expansion and assertions;
* the current C parser, foreign-type conversion, checker call adjustments, code generator, and cprobe baseline all work unchanged;
* types and single evaluation at the Titan call boundary are explicit;
* address-taking denotes a real inline function, so existing C-function rules remain honest;
* optimized production builds normally inline the call; `-O0` test/sanitizer builds may retain a small local call without changing behavior;
* the supported surface is visibly an audited Titan bridge, not a promise about every macro in an imported header.

No parser, AST, type, checker, coder, or new semantic probe change is required **for macro access** under this option. The separate `foreign function` feature still requires the changes already described by the draft.

### Option B: direct generated macro invocation

Direct support can be made sound, but it needs an explicit signature source. The smallest C-side contract is a parenthesized prototype after the real macro is visible:

```c
extern CClosure *(clCvalue)(const TValue *o);
```

The parentheses suppress expansion in the declarator; generated `clCvalue(arg)` still expands. There need be no linked function definition if the checker permits only direct invocation and verifies the macro remains active. A Titan syntax such as a typed `foreign macro` declaration could supply the same contract, but that is a larger language feature. Hard-coding the four Lua names in the compiler is not acceptable.

If direct support is selected, make these exact changes:

1. **Contract and preprocessing (`c-parser/cdefines.lua`, `c-parser/cdriver.lua`).** Preserve a structured function-macro descriptor: public name, formal names, fixed/variadic shape, replacement tokens/provenance, and active-definition identity. Do not expand the replacement in Titan. Associate it with an explicit parsed prototype or source annotation. Existing `macro_definitions`/`macro_changes` plumbing should be reused, not duplicated.
2. **Final environment (`titan-compiler/symtab.lua`).** Add a cached classifier/query for the final active function macro, analogous to field-macro classification. Generated includes are hoisted, so a later `#undef` or redefinition must affect every generated call. A prototype without an active function macro is an ordinary function; an active macro without a trusted signature is not a callable FFI member.
3. **Representation (`foreigntypes.lua`/checker).** Represent it as a declaration-only `Checker.CMacroCall` (or equivalent) containing a `Type.CFunction` signature, not as a first-class `Type.CFunction` value. This follows Titan's existing separation between FFI declarations and callable values and avoids auditing/serializing a misleading new type tag.
4. **Checking (`checker.lua`).** Permit only the direct callee position, apply the signature's ordinary C argument/result adjustments, and reject address-taking, assignment to a function pointer, bare value use, and named-argument reinterpretation. Initially accept only fixed-arity, monomorphic contracts; reject variadic, `#`, `##`, type-operand, statement-expression, and signature-dependent forms rather than guessing. Under the trusted model this is a supported-surface restriction, not hostile-input hardening.
5. **Emission (`coder.lua`).** Annotate the checked call and emit the original identifier followed by the already generated argument expressions. Never splice or evaluate the replacement tokens in Lua. Document that C macro semantics govern evaluation: a macro may evaluate an argument more than once, unlike a function. The four Lua accessors are audited single-use macros and callback arguments have no side effects.
6. **Probe (`cprobe.lua`, with `cdeclarator.lua`/`cpreamble.lua`).** Add a session-scoped, cached compile-only invocation probe in the exact final include context. Render typed dummy parameters and a call `NAME(p0, ...)`, returning or assigning its result according to the explicit contract. This validates that the final macro is callable with the contract and the configured C99 toolchain; the trusted prototype remains authoritative because portable C99 cannot reflect an arbitrary expression's exact type. Treat infrastructure failure like existing semantic probes and do not cache it as a semantic answer.
7. **Parser/AST.** No Titan parser change is needed if the signature is supplied by a Titan-owned parenthesized C prototype. A source-level `foreign macro` annotation would require its own AST/parser/checker syntax and both manuals; do not smuggle this through `foreign function` or an ordinary alias.

Raw `foreign import "lobject.h"` still has no signatures, so direct `lobject.clCvalue` cannot arise merely by stopping the current skip. It requires the source-level annotation above, a Titan-owned typed overlay imported under the chosen alias, or compiler hard-coding. The overlay is the only small sound choice, at which point `lmacro_*` wrappers are simpler and more honest for this release.

### Rejected same-spelling inline compromise

This also compiles and parses:

```c
static inline CClosure *(clCvalue)(const TValue *o) { return clCvalue(o); }
```

It makes raw generated calls expand when the macro is active, but silently falls back to an addressable inline function after a later `#undef`. It also makes `&ffi.clCvalue` appear valid and hides the macro/function distinction. That identity trick is less clear than `lmacro_clCvalue` and does not justify its architectural ambiguity.

### Decision matrix

| Property | `lmacro_*` inline wrapper | Direct macro with explicit contract | Unannotated direct macro |
|---|---|---|---|
| Host C preprocessor performs expansion | yes, in wrapper body | yes, at generated call | yes |
| Trustworthy parameter/result type | explicit C function | explicit companion contract | no |
| First-class/address semantics honest | ordinary inline function | checker must reject | no |
| New compiler/probe path | none | substantial narrow path | cannot be made sound generally |
| Multiple-evaluation exposure | wrapper evaluates actual once | macro-defined | macro-defined |
| Works with current `cdriver` | verified | prototype parsing verified; semantic classifier missing | macro hidden from namespace |
| Best scope for this wrapup | **yes** | future opt-in feature | no |

## Tests and validation

### Compiler-level wrapper/foreign-function tests

* Parse/check/generate one callback-shaped foreign function using all four `lmacro_*` wrappers and verify that no redundant owner-push helper is emitted.
* Compile the installed `titan/ffi.h` as C99 in the normal final include order; exercise both GCC/Clang in CI where available through the existing Linux/macOS toolchains rather than adding an unrelated matrix.
* Assert the correct `lmacro_clCvalue` spelling and pointer constness.
* Verify a foreign callback can take an imported inline wrapper's result, cast native entry `void *` to a `foreign (...) -> ...` function pointer, call it, and restore the stack.
* Keep generic foreign-function parser/checker/coder restrictions in their topical specs; the standard-library suite should test observable callback behavior, not duplicate codegen inspection.

If direct macros are chosen instead, add focused cases to `cpp_spec.lua`, `cdriver_spec.lua`, checker C-FFI specs, `cprobe_spec.lua`, and coder C-FFI specs for fixed arity, final redefinition/undef, direct emission, no address-taking, side-effect/multiple-evaluation documentation, probe cache/infrastructure failure, and rejection of unsupported variadic/stringify/paste forms.

### Structural shim-removal gates

Revise `spec/libuv_build_spec.lua` rather than deleting its unique structural oracle:

* assert `titan-runtime/titan_uv.c`/`.o` and `titan_httpshim.{c,h}`/`.o` are absent from sources, build rules, stamps, CPPFLAGS, and payload;
* assert `libtitan.a` has exactly `titan.o`, `titan_coro.o`;
* assert `titan_coro.o` still defines minicoro API and the reduced source still selects a fixed comparator, but no longer exports/references `titan_coro_entry`;
* inspect `titan/uv/uv.o` (without `nm -g` if generated foreign functions are local/hidden) to prove the new callback functions are defined in the logical module, while `nm -u` shows no legacy `titan_uvshim_*` references;
* inspect the generated HTTP logical object/provider for the eight callback definitions and no legacy `titan_httpshim_*` references;
* keep `libtitan-llhttp.a` exactly `llhttp.o`, `http.o`, `api.o` and prove the provider/archive still contains `llhttp_execute`;
* prove combined `titan.a` has no metadata-free `titan_httpshim.o` leaf and the bundled/system `-X` order is now `titanlib.o`, LPegLabel, selected libuv payload, llhttp archive, selected OpenSSL payload;
* keep the retired-wrapper/helper absence checks, updating their owning object rather than weakening them.

Update the exact two-member fixtures in `driver_spec.lua`, `rockspec_spec.lua`, and the BSD ranlib-index fixture. Update source-rock contents and SDK header assertions (`titan/coro.h` gone, `titan/uv.h` retained).

### Behavioral/lifetime gates

The unified native stdlib suite already reaches coroutine entry, all major libuv owner shapes, filesystem callbacks, process/signal/network callbacks, Runtime walks/closes, timers, and HTTP parsing. Retain the full uncovered run and both bundled/system production smokes.

Keep or strengthen these focused sanitizer gates:

* coroutine payload/tag GC (`test_lua_host_roots_coroutine_payloads_and_tags_across_gc`);
* timer and filesystem filters;
* `uv.task_tests` and `uv.runtime_tests`;
* TLS/HTTP fresh-process composition.

Add one focused owner-root regression only if existing tests do not deterministically do this sequence: enter the callback, remove the Runtime/request/parser's last external owner root, force a collection inside the Titan continuation, then read the owner/capture and verify the callback restores the exact stack top. This proves the correction from “push module” to “push owner” without inspecting generated implementation in a library behavior test.

Run, in order:

1. focused pure/parser/checker/coder specs for foreign functions and wrappers;
2. `make llhttp`, runtime archive, `spec/libuv_build_spec.lua`, `spec/driver_spec.lua`, and `spec/rockspec_spec.lua` in a fresh prefix;
3. `make stdlib-test` and the complete compiler group after reinstalling the rock;
4. bundled and system production smokes;
5. sanitizer gates;
6. manual-dispatch macOS suite before merge.

## Documentation and ABI checklist

This is user-visible language work, so land both a language chapter for `foreign` functions/`foreign` function types and an implementation chapter, linked from both indexes. For the shim migration, update at least:

* `doc/implementation/{coroutines,http-library,libuv-extension-guide,libuv-networking,libuv-runtime,driver,folder-modules,lpeglabel-embedding,index}.md`;
* `doc/async-with-coroutines.md`;
* `doc/language/{modules,multi-module-libraries,static-compiled-modules}.md` where runtime/archive/ABI history is stated;
* `README.md`, `doc/style-guide.md`, and `AGENTS.md` exact archive, callback-boundary, and SDK-header descriptions.

Retain the feature rationale that the earlier ABI boundary introduced promoted
libuv callback symbols. Add the new ABI transition explaining that generated
foreign callbacks retire those symbols and that old providers/runtimes cannot
be mixed. Advance `TITAN_ABI_VERSION`, generated metadata, ABI-keyed caches,
stdlib stamps, shims, tests, and docs together according to the ABI checklist.

## Suggested implementation order

1. Land the general `foreign function`/`foreign <function type>` compiler behavior and topical tests, including generated headers.
2. Add and test `lmacro_*` plus the raw owner-push helper.
3. Convert coroutine entry; reduce `titan_coro.c`; delete `coro.h`; keep comparator/minicoro tests green.
4. Convert libuv callbacks contributor by contributor, preserving callback shapes and owner roots; then remove `titan_uv.c`, its object/stamp, and callback declarations from `uv.h`.
5. Convert HTTP callbacks; then remove HTTPS shim source/header/object and payload/include/checksum wiring.
6. Change runtime/archive/rockspec exactness and ABI together, update manuals, and validate fresh bundled/system prefixes.

Do not combine this with a per-runtime minicoro comparator redesign, renaming every surviving `titan_uvshim_*` storage typedef, generic macro type inference, or compatibility cleanup. Those are separable decisions and add no value to the supported shim-removal boundary.
