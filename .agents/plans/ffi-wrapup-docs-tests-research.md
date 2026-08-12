# FFI wrapup: documentation, grammar, ABI/artifact, and test research

Status: research only. This does not change the draft plan or implementation.

## Executive conclusions

1. The complete wrapup is large enough to deserve a paired manual chapter for
   `foreign function` (language and implementation), linked from both indexes.
   The existing FFI chapters should continue to own FAM allocation and the
   target-directed `.new`/`.new_array` storage rules rather than duplicating
   them in the new chapter.
2. `foreign` is already a reserved token, but the documented and real grammar
   need a new top-level declaration, a C-function-pointer type constructor, and
   general initialized C array-view/fixed-array type forms required by the
   draft's examples. The old initializer-less automatic-local production must
   be retired.
3. The new syntax and local C types do **not**, by themselves, change serialized
   Titan module interfaces or the Titan native calling convention. The full
   draft nevertheless **does require an ABI bump (0.22 -> 0.23) if the current
   runtime callbacks are removed as specified**. ABI 0.18 established the exact
   precedent: old `titan.a` logical objects have undefined references to
   `titan_coro_entry`/`titan_uvshim_*` supplied by the unversioned runtime SDK
   archive. Removing those definitions makes an old-0.22-provider/new-runtime
   static pairing fail even though its public type metadata still says 0.22.
   Keeping compatibility objects would contradict the draft and Titan's
   clean-break prototype policy.
4. A generated module header is a source-build artifact, not another provider
   artifact. It should not enter `.titan.meta`, the paired-provider publication
   transaction, generated Lua shims, the installed standard image, or the rock
   manifest. Direct source provenance is what permits access to foreign
   members; a DSO/archive import remains public-only.
5. Use the current source-adjacent ownership model, not new defensive machinery:
   once the exact header basename is chosen, document it as compiler-owned in
   the same way as the same-stem `.c`/`.o`, retire stale headers when a module no
   longer has foreign members, and clean only derivable or exact known paths.
   Do not scan installation directories or invent compatibility headers.
6. For the Lua-internal accessor need, small typed `static inline` wrappers in
   `titan/ffi.h` are the narrow path. General function-like macro exposure would
   be a separate typed-language feature: emitting the public spelling is easy,
   but arity, argument/result types, repeated evaluation, and use-site probing
   are not currently represented. Unless that broader feature is explicitly
   chosen, retain the manuals' general “function-like macros are unavailable”
   boundary.

## Authorities and current contracts reviewed

The main current authorities are:

* `README.md` (SDK file table, tests, cleanup, tentative roadmap, ABI history);
* `doc/language/{index,ffi,c-ffi-expressions,grammar,types,statements,functions,
  modules,source-import-visibility,folder-modules,multi-module-libraries,
  static-compiled-modules}.md`;
* `doc/implementation/{index,ffi-internals,c-ffi-expressions,ast-typedecl,
  lexer-parser,checker,type-relations-and-boundaries,codegen-overview,driver,
  source-import-visibility,folder-modules,multi-module-libraries,
  static-compiled-modules,coroutines,libuv-runtime,libuv-extension-guide,
  libuv-networking,http-library,lpeglabel-embedding}.md` and
  `doc/async-with-coroutines.md`;
* `titan-runtime/titan.h`, the ABI specs, and the provider/publication chapters;
* `Makefile`, `scripts/stdlib_installer.lua`, the cleanup helper, packaging/build
  specs, and `spec/support/ci_test_groups.sh`.

Current facts that the final documentation must deliberately replace rather
than coexist with:

* Language grammar already reserves `foreign`, but top-level grammar has only
  `local x = foreign import ...`; there is no foreign-function declaration or
  foreign function-type production.
* Source-written `c.T[N]` exists only in the parser's special one-variable,
  no-initializer automatic-local production. `c.T[]` is not source syntax
  except inside `owned c.T[]`.
* `.new()` and `.new_array(n)` currently always infer `owned *T` and
  `owned T[]`, allocate zeroed Lua userdata, and may initialize module state.
* FAM metadata is already retained by the C parser, but allocation and direct
  indexing/length are explicitly rejected.
* A direct source import has a compiler-only private overlay; C header origins
  are use-driven and are not serialized. Binary imports and Lua are public-only.
* A flat module writes `.c/.o` beside its source; a folder module writes them
  beside its canonical main and contributors produce no artifacts. Providers,
  shims, and executables are working-directory outputs.
* Paired publication owns only the staged DSO, archive, logical Lua shims, and
  Darwin dSYM. Standard installation additionally owns the canonical
  `titan/test.titan` compiler source. It does not publish source-adjacent C/O
  intermediates.
* Installed `libtitan.a` currently has exactly `titan.o`, `titan_coro.o`, and
  `titan_uv.o`; the SDK currently installs `titan/{ffi,coro,uv}.h`; and the
  standard `-X` payload currently includes `titan_httpshim.o` before llhttp.
* Standard-library behavior is native Titan under `spec/stdlib/titan/` and is
  intentionally outside LuaCov. Compiler/checker/coder behavior belongs in
  root, `spec/checker/`, and `spec/coder/` respectively.

## Required documentation checklist

### New paired chapters and indexes

* [ ] Add `doc/language/foreign-functions.md` covering the source syntax,
  C-ABI type, call/pointer use, visibility, restricted body, literals/`NULL`,
  header artifact, and the inline-header subset.
* [ ] Add `doc/implementation/foreign-functions.md` covering the AST/type nodes,
  parser productions, specialized body checker and code generator, C linkage
  and mangling, header construction/include graph, inline classification, and
  why the construct is absent from binary metadata.
* [ ] Link both chapters from `doc/language/index.md` and
  `doc/implementation/index.md`; update their C-FFI status/limitation summaries.
  This follows the repository rule that a sizable user-visible feature lands in
  both manuals in the same change.

### Language reference edits

* [ ] `doc/language/ffi.md`
  * distinguish imported C declarations from Titan-written `foreign function`;
  * define a foreign function as a C declaration/function-pointer surface, not
    a `Type.Function` value or an adapter for an ordinary Titan closure;
  * exclude foreign functions from implicit `L` (and implementation `M`) state;
  * replace “Titan functions cannot be callbacks” with the precise remaining
    boundary: ordinary Titan functions/closures are not adapted, while a
    Titan-written foreign function already has the requested C ABI;
  * rewrite `.new`/`.new_array` from always-owned constructors to the complete
    local-initializer target matrix, while retaining module-variable owned
    allocation where the draft does not change it;
  * document stack lifetime, hidden owner lifetime for a bare pointer target,
    and copy/allocation when an automatic aggregate/array is coerced to an owned
    target;
  * define FAM arities (`T.new(fam_count)` and
    `T.new_array(array_count, fam_count)`), zeroing, negative-count and overflow
    behavior, and the observable indexing/length contract once settled;
  * remove FAM rejection and change adopted pointers from a promised later
    feature to simply unsupported (borrowed raw pointers and Titan-owned storage
    remain the supported ownership modes);
  * update the header-support section for any new `titan/ffi.h` inline accessors;
  * retain or revise the function-like-macro limitation according to the one
    implementation choice actually made.
* [ ] `doc/language/c-ffi-expressions.md`
  * replace “initializer-less automatic objects/fixed arrays” with
    initializer-driven `.new`/`.new_array` automatic storage;
  * rewrite the callback-options example to use the new construction form and,
    preferably, a real `foreign function` callback;
  * document general initialized `c.T[N]`/`c.T[]` views if those spellings are
    adopted, decay/address-taking, C block lifetime, and aggregate-to-owner copy;
  * update longjmp language only for ordinary Titan functions; foreign bodies
    have no catch/defer/raise boundary;
  * update the macro section only if a supported function-like subset is truly
    implemented.
* [ ] `doc/language/grammar.md`
  * add `tlforeignfunc` and include it in `tldecl`;
  * add the `foreign <function type>` type form with its exact precedence;
  * add the initialized C fixed/unsized array forms required by the examples;
  * remove `automaticlocaldecl` from `statement` and its special extent grammar;
  * document semantic restrictions that are checker rules rather than bloating
    EBNF (FFI-only params/results/locals, no tails, restricted statements);
  * keep `foreign` in the existing reserved-word list—no new lexical token is
    needed.
* [ ] `doc/language/types.md` and `doc/language/functions.md`
  * distinguish `Type.Function` from a foreign C function pointer;
  * add the automatic aggregate/array -> pointer and -> owned-copy rows to the
    direct conversion table if they are general coercions;
  * state that foreign functions can be called/taken as C function pointers but
    are never boxed Titan function values.
* [ ] `doc/language/statements.md` remove the no-RHS C-local exception and point
  to `.new`/`.new_array` for zero-initialized automatic storage.
* [ ] `doc/language/source-import-visibility.md` add foreign functions to the
  direct-only collaboration surface. Explain that their generated prototypes
  travel through a generated C header, not serialized module metadata, and do
  not expose a producer's foreign-import alias.
* [ ] `doc/language/modules.md` and `doc/language/folder-modules.md` add the
  generated-header column/path and state that only the flat source or canonical
  folder main owns it; contributors own none.
* [ ] `doc/language/multi-module-libraries.md` and
  `doc/language/static-compiled-modules.md` state that generated source headers
  are not provider-bundle members or metadata. Add the 0.23 compatibility
  rationale while retaining 0.18 as history.
* [ ] Sweep current-version prose in the quick tour, Lua interop, philosophy,
  Arrays, Interfaces, functions, and other active manuals from 0.22 to 0.23;
  preserve historical statements as history rather than rewriting their facts.

### Implementation manual edits

* [ ] `doc/implementation/ast-typedecl.md` inventory the new top-level/type AST
  constructors and decorations; foreign declarations must not masquerade as
  ordinary `TopLevelFunc`/`Type.Function` if that would let ordinary visitors
  assume `_mod`/closure semantics.
* [ ] `doc/implementation/lexer-parser.md` explain the new productions,
  diagnostics, type precedence, removal of the automatic-local branch, and
  inline-body shape recognition ownership (checker/coder, not parser, unless
  the final implementation deliberately annotates it there).
* [ ] `doc/implementation/checker.md` and
  `type-relations-and-boundaries.md` describe the isolated foreign-body symbol
  environment and storage-target plans. The coder must consume a frozen plan;
  it must not rediscover “stack versus owner” from endpoint tags.
* [ ] `doc/implementation/ffi-internals.md`
  * add the foreign-function C type/declaration path and direct-source overlay;
  * revise `CStruct.has_fam`, allocation eligibility, owner byte/count metadata,
    and the FAM-size calculations;
  * revise the checker/codegen sections for contextual pseudo-constructor
    results and hidden roots/copies;
  * update `titan/ffi.h` contents and the macro limitation.
* [ ] `doc/implementation/c-ffi-expressions.md` replace the current dedicated
  no-RHS `Ast.TypeCArray` design with the initialized target matrix, including
  automatic objects, fixed arrays, raw array views, owner copies, FAM layout,
  and ordinary-function longjmp spills.
* [ ] `doc/implementation/codegen-overview.md` document the fourth entry kind:
  a plain C ABI function with no `L`, `_mod`, `_fn`, Lua entry, closure, module
  slot, or trace-name registration unless explicitly added. Document where
  foreign definitions and prototypes are emitted.
* [ ] `doc/implementation/source-import-visibility.md` distinguish use-driven C
  origin headers from the generated-header edge needed for a directly imported
  foreign member, especially for inline bodies. Keep permission direct-only and
  provenance-based.
* [ ] `doc/implementation/driver.md` document header path derivation, generation
  ordering before dependent C compilation, stale-header removal, compile include
  resolution, final runtime archive membership, installed SDK header set, and
  removal of the HTTP adapter from standard payload.
* [ ] `doc/implementation/folder-modules.md` add the canonical-main header path
  and the “no contributor header” rule.
* [ ] `doc/implementation/multi-module-libraries.md` and
  `static-compiled-modules.md` keep publication validation limited to logical
  protocols/provider forms and explain that private foreign symbols may be
  physical object members without metadata keys. Update standard payload order
  and ABI 0.23.
* [ ] Rewrite current shim descriptions in
  `doc/implementation/{coroutines,libuv-runtime,libuv-extension-guide,
  libuv-networking,http-library}.md` and `doc/async-with-coroutines.md` to point
  at source-owned foreign callbacks. Remove the HTTP adapter from
  `lpeglabel-embedding.md`, `string-library.md`, folder/provider payload
  examples, and index summaries.
* [ ] Update `doc/implementation/index.md` repository map and known-limitations
  table: runtime archive members, installed headers, callback ownership, FAM
  support, automatic storage, and the chosen macro boundary.
* [ ] Update `AGENTS.md` after implementation: prerequisites/SDK inventory,
  runtime archive members, standard `-X` payload, source callback ownership,
  generated header/cleanup rules, ABI 0.23 paths, sanitizer snapshot inputs, and
  spec placement. Do not edit historical draft plans or the worklog merely to
  make old prose look current.

### README / roadmap

* [ ] Move the completed parts of “FFI with C, continued” into the Supported FFI
  bullet: Titan-written C-ABI functions/callbacks, FAM-owned allocation, and
  target-directed automatic/owned local allocation.
* [ ] Remove the “FFI with C, continued” Next item and do not move adopted
  pointers elsewhere in the roadmap.
* [ ] Update the SDK file table, runtime archive members, installed headers,
  standard payload description, ABI/path text, generated-artifact table, and
  cleanup prose.

## Grammar and semantic points that must be settled before the manuals can be final

These are specification gaps in the draft, not requests for defensive
machinery:

1. **Exact array type grammar.** The examples require initialized `c.T[3]` and
   `c.T[]`, while the last paragraph says the special no-RHS `c.T[3]` form goes
   away. Decide whether fixed/unsized arrays become general C annotation forms
   or only contextual local-target forms, and whether `local x: c.T[3]` is a
   syntax error or an ordinary missing/nil-initializer type error. The current
   grammar cannot parse the initialized examples.
2. **FAM array meaning.** C99 forbids a structure containing a flexible-array
   member as an element of a normal C array, and ordinary `T *` pointer
   arithmetic uses `sizeof(T)`, not a Titan-chosen extended stride.
   `new_array(array_count, fam_count)` therefore needs a documented Titan layout
   and explicit rules for indexing, decay/passing to C, `#`, and access to each
   FAM. Do not imply it is an ordinary C `T[array_count]` unless the host C
   contract actually supports that representation.
3. **Where FAM counts live.** A scalar owner can potentially derive the FAM
   count from total payload bytes, but an array owner has both an element count
   and FAM count. Specify the observable count/bounds policy before documenting
   it; do not add guessed metadata solely for hardening.
4. **Pseudo-constructor contexts.** The draft says “when used to initialize a
   new local variable.” State what module variables, returns, call arguments,
   assignments to existing locals, and foreign-function locals do. Existing
   module-variable allocation is an important rooted-owner contract and should
   not change accidentally.
5. **Foreign-body safe subset.** Several existing C-expression lowerings can
   call `luaL_error` for null pointers, bounds, allocation overflow, or checked
   scalar conversion. A foreign function has no implicit `L`. The final spec
   must say whether those operations are rejected or lowered with raw C
   semantics. “All existing FFI expressions” is not precise enough. Likewise,
   settle `do`, `break`, and void call statements; the draft's allowed-statement
   parenthesis omits constructs needed by ordinary C-like code while its example
   already uses call statements.
6. **Inline address identity and “constant” wording.** A `static inline`
   definition in each including translation unit can have a different function
   address, and a C inline call is not a C integer constant expression. Promise
   optimization/header availability, not formal constant-expression semantics,
   unless the implementation actually emits a macro or `_Static_assert`-usable
   construct.
7. **Header basename.** The draft promises “a `.h`” but not its path. Choose it
   once and add it to all flat/folder/external-tree artifact tables. The natural
   continuation of current ownership is the generated-C stem (`foo/bar.h` and
   folder `foo/bar/bar.h`), reserved as compiler-owned when applicable.

## ABI decision and bump checklist

### Decision

**Bump to ABI 0.23 for the full plan as written.** The reason is the native
runtime/static-provider contract, not the presence of a new keyword or header:

* foreign functions, C function-pointer aliases, FAM owners, and automatic C
  storage are local C types and remain rejected from serialized interfaces;
* generated headers are compiler-only source collaboration artifacts;
* but current 0.22 standard archive objects directly reference callbacks from
  `titan_coro.o`/`titan_uv.o`, while `libtitan.a` is deliberately not flattened
  into a generated provider archive;
* replacing those callbacks with functions defined in new generated logical
  objects and removing the runtime objects leaves an old `titan.a` unable to
  link against the new unversioned `libtitan.a`;
* the language and implementation manuals explicitly record this exact class of
  static provider/runtime mismatch as the reason ABI 0.18 existed.

If the callback symbols and compatible runtime objects were retained, the
language pieces alone would not justify a bump. That is not the full draft, and
retaining them only as compatibility shims would be an unnecessary epicycle.
The HTTP adapter removal alone is internal to the standard provider payload and
would not force the bump; the runtime archive boundary does.

### Coordinated 0.23 work

* [ ] Advance `driver.TITAN_VER`, `TITAN_VER_SUFFIX`, `titan.h`, Make's active
  ABI, `TITAN_PATH_0_23`, `lib/titan/0.23`, `share/titan/0.23`,
  `stdlib_0_23`, CI cache/env/path checks, smoke/snapshot helpers, and all active
  standard-install paths together.
* [ ] Add the 0.22 -> 0.23 rationale to `titan.h` and compatibility manuals:
  generated standard objects now own foreign callback definitions and the
  former runtime callback symbols/members are absent.
* [ ] Change `spec/abi_spec.lua` to reject a 0.22 DSO/archive before metadata
  decoding or native linking, and to ignore `TITAN_PATH_0_22` when 0.23 is
  active.
* [ ] Preserve a separately installed 0.22 tree. Do not migrate it, remove it,
  synthesize child copies, or teach the 0.23 publisher to treat a 0.22 pair as
  an active-layout predecessor.
* [ ] Update active standard-installer predecessor rules for a clean 0.23
  namespace. Do not carry historical same-namespace predecessor machinery
  unless a real 0.23 predecessor exists.
* [ ] Update type-schema fixtures only for actual public standard-interface
  changes. Foreign locals themselves must not appear in the eighteen logical
  public schemas.

## Generated header ownership, publication, and cleanup

### Ownership and paths

* One logical module has at most one generated header, beside the same flat
  source or canonical folder main that owns its `.c/.o`. Contributors never own
  one. An external `--tree` continues to place it beside the external canonical
  source, matching current C/O behavior.
* The header must be regenerated/removed as a unit with that module's generated
  C. A successful rebuild after deleting the last foreign member must remove a
  stale prior header so another source compiler cannot see declarations that no
  longer exist.
* Treat the chosen same-stem path as compiler-owned, rather than adding a
  content-signing or transaction protocol. If users must be able to own a
  same-stem C header, choose a distinct generated suffix now; do not attempt to
  guess ownership later.
* Use include guards and normalized include spellings for ordinary C
  correctness. The header includes the module's FFI headers and generated
  headers for direct source dependencies whose foreign members can be named.
  This include graph supplies C declarations; it does not grant Titan
  capability or make private access transitive.

### What is not published

* Do not add generated headers to `.titan.meta`, `<mangled>_types`, the DSO ABI
  claim, archive key sets, logical Lua shims, dSYM transaction, or
  `scripts/stdlib_installer.lua`'s canonical public file set.
* Do not install standard generated headers under `<root>/include`: they expose
  local source-collaboration functions, not a binary SDK API. A binary consumer
  cannot recover their types from metadata and must not gain them from an
  ambient header.
* Non-inline foreign definitions live in their owning generated object and may
  be physical native symbols; inline definitions live in the header. Neither
  form creates another logical module or metadata key.

### Runtime/standard artifact consequences

* Remove the obsolete C callback sources/headers and their Make inputs only
  after the foreign replacements exist. Update the exact `libtitan.a` member
  assertion to the final retained runtime objects; do not use a wildcard.
* Remove `titan/coro.h` and `titan/uv.h` from SDK staging if no retained types
  still require them. Keep and document `titan/ffi.h` and `minicoro.h` as
  appropriate. `uv.h`/`uv/` remain governed by bundled/system libuv policy.
* Remove `titan_httpshim.o` and its include flags/source-package entries from the
  standard payload and completion/config stamps. Keep llhttp itself as private
  metadata-free payload.
* Update `nm`/archive tests so generated coroutine/uv/http objects define the
  new mangled foreign callbacks and neither the objects nor installed
  `libtitan.a` reference/define the retired shim names.

### Cleanup and diagnostic snapshots

* Extend `spec/support/clean_generated_test_artifacts.sh` to remove a generated
  `.h` only under the same bounded ownership rule as generated `.c` (same-stem
  `.titan` or an exact reserved synthetic pattern), and extend its preservation
  test with an author-written unrelated header.
* Add exact known standard generated headers to `make clean`; do not use broad
  `titan/**/*.h`, `examples/*.h`, or `spec/**/*.h` globs that would delete
  author-written native fixtures. Each fixture spec must remove its exact
  generated header in teardown.
* Add exact ignore entries for checkout-generated standard headers rather than a
  repository-wide `*.h` ignore.
* The sanitizer generated-C snapshot currently saves only `.c/.o` pairs plus
  compile argv, then recompiles a relocated shadow C file. Once generated C
  depends on generated headers (especially inline bodies), snapshot the exact
  header closure too, or otherwise make the shadow compile consume a preserved
  immutable copy. Do not let the failure-only mapper silently read a later or
  missing checkout header.

## Layered local test plan

### Layer 1: pure lexer/parser/AST/type units

* `spec/lexer_spec.lua`: `foreign import`, `foreign function`, and `foreign`
  type uses remain uniquely tokenized; identifiers containing `foreign` remain
  names.
* `spec/parser_spec.lua`: positive AST subsets for foreign declarations and
  foreign function types; precedence/nesting; no `foreign local`; malformed
  params/results; initialized `T[N]`/`T[]`; rejection of the retired no-RHS C
  declaration; source locations and dedicated syntax labels.
* `spec/typedecl_spec.lua`/`spec/types_spec.lua`: constructors, rendering,
  equality, direct-C predicates, and proof that serialization rejects every
  foreign/C-bearing public type.
* `spec/ctypes_spec.lua`, `spec/foreigntypes_spec.lua`, and relevant
  `cdeclarator` units: retain FAM owner/member identity and render exact
  function/array declarations.

Suggested first command after Lua syntax checking touched compiler chunks:

```sh
"$PREFIX/bin/busted" spec/lexer_spec.lua spec/parser_spec.lua \
  spec/typedecl_spec.lua spec/types_spec.lua spec/ctypes_spec.lua \
  spec/foreigntypes_spec.lua
```

### Layer 2: checker-only compiler behavior

Add a sizable topical `spec/checker/c_ffi_foreign_functions_spec.lua` rather
than growing the omnibus FFI spec. Cover:

* zero/single C result and fixed FFI params; call and C-pointer conversion;
* direct source visibility, direct-only permission, and binary/public rejection;
* absence of ordinary module state/functions/variables and implicit `L`/`M`;
* every prohibited result/param/local/cast and body construct (multiple/flex,
  vararg, Titan/value types, catch/defer/raise, generic for, case, and the final
  settled restrictions for `do`/`break`/calls);
* imported C namespaces and other visible foreign functions as the only callable
  environment;
* string literal -> `const char *`, nil -> `NULL`, and diagnostics for
  operations that would require a missing Lua error state.

Extend `c_ffi_owned_types_spec.lua` for FAM arity/eligibility/counts and
`c_ffi_stack_objects_spec.lua` for the complete target matrix, including
aggregate/array -> pointer and -> owned-copy plans, constant versus dynamic
array counts, and the retired no-RHS path. Keep relation truth tables in
`spec/types_spec.lua`.

### Layer 3: generated C and run-time compiler fixtures

Add `spec/coder/c_ffi_foreign_functions_spec.lua` with small real C headers/host
functions. Assert and execute:

* exact C prototype and definition, mangled injective name, and no hidden
  `L/_mod/_fn`, Lua entry, closure, or module slot;
* direct calls and passing the generated function to a host C callback API;
* loops/branches/assignments/returns, pointer calls, nil/string lowering, and
  evaluation exactly once;
* generated header prototypes/includes and all three inline body shapes plus
  close near-misses that remain out-of-line;
* two source translation units calling the same foreign member and a direct
  source dependency used from an inline body;
* foreign locals remain absent from callable/embedded public metadata.

Extend coder owned/stack-object specs with host-side layout checks:

* scalar FAM allocation and, after its semantics are settled, multiple extended
  elements, alignment/stride, zeroing, bounds/length, negative counts and size
  overflow;
* inferred/annotated `.new` matrix and constant/dynamic `.new_array` matrix;
* automatic address-taking, hidden owner rooting, and copy-to-owner independence;
* ordinary-function catch/finally spill behavior after construction;
* side-effecting count expressions run once.

If wrappers are chosen, test their real declarations through
`titan/ffi.h`. If general function-like macros are chosen instead, add pure
preprocessor/type-extraction tests plus checker/coder tests for exact arity,
static types, public-spelling emission, and macro argument evaluation; do not
claim the feature from one Lua-internal example.

### Layer 4: driver, source layout, provider, and cleanup

* Extend the foreign-function coder spec or a focused driver spec for flat,
  folder-main, contributor, and external-tree header paths; generation order;
  stale-header retirement; and the chosen same-stem ownership rule.
* Extend `source_import_local_visibility_spec.lua` for generated-header direct
  calls and normalized quoted origins. A compiled provider of the same module
  must expose no foreign member.
* Extend `folder_modules_spec.lua` and multi-module preflight tests: one header
  per logical folder module, none per contributor, injective foreign symbols,
  and no header in provider publication.
* Extend the cleanup ownership test and sanitizer-context snapshot spec to prove
  headers are removed/preserved/copied exactly as described.

### Layer 5: ABI, build, packaging, and installed SDK

* `spec/abi_spec.lua`: coordinated 0.23 constants and early 0.22 rejection.
* `spec/driver_spec.lua`: exact final runtime archive members and normal links
  through the whole archive.
* `spec/libuv_build_spec.lua`: no C callback/HTTP adapter sources or objects;
  exact new generated callback symbols/references; revised standard payload,
  config prerequisites, cleanup, and current public type-schema fixture.
* `spec/rockspec_spec.lua`: final installed SDK header list, source archive no
  longer contains `titan_httpshim.{c,h}`, no generated local headers installed,
  and both bundled/system installs work outside the checkout.
* `spec/stdlib_installer_spec.lua`, static/multi-module specs, and support scripts:
  active 0.23 paths, preserved 0.22 tree, unchanged eighteen-key logical
  provider, paired rollback/equivalence, and archive-backed validation.

Because Busted loads the installed compiler snapshot, reinstall the edited
compiler before these native/compiler tests:

```sh
export PREFIX=/tmp/titan-$USER-ffi-wrapup
export PATH="$PREFIX/bin:$PATH"
unset ROCKS_TREE TITAN_ROCKS_ROOT TITAN_EXTRA_CPPFLAGS TITAN_NO_LINE_DIRECTIVES
"$PREFIX/bin/luarocks" make --force
"$PREFIX/bin/busted" spec/checker/c_ffi_foreign_functions_spec.lua \
  spec/checker/c_ffi_owned_types_spec.lua \
  spec/checker/c_ffi_stack_objects_spec.lua
"$PREFIX/bin/busted" spec/coder/c_ffi_foreign_functions_spec.lua \
  spec/coder/c_ffi_owned_types_spec.lua \
  spec/coder/c_ffi_stack_objects_spec.lua
"$PREFIX/bin/busted" spec/abi_spec.lua spec/driver_spec.lua \
  spec/libuv_build_spec.lua spec/rockspec_spec.lua \
  spec/stdlib_installer_spec.lua
```

### Layer 6: source-authoritative standard-library behavior

The shim replacement and allocation audit must retain observable behavior in
native Titan suites, not new Lua/Busted boundary suites. Run focused fresh
processes for coroutine transfer/GC, uv callbacks and cleanup, async
continuations, filesystem, network, process/stdio, and HTTP parser callbacks,
then the full suite:

```sh
make titan-stdlib-test TITAN_FILTER='^(coroutine|uv|async|fs|net|os|http)[.]'
make stdlib-test
```

`TITAN_FILTER` changes execution only; all 22 roots still compile together from
source. This is valuable here because it forces every collaborating standard
root through the new generated-header path and prevents a stale binary from
hiding a source error. Keep these library tests outside LuaCov. Retain focused
ASan+UBSan callback/lifetime filters in CI, including coroutine transfer,
request/handle owner GC, process stdio, and HTTP/TLS parsing.

### Layer 7: complete local gates

```sh
bash spec/support/ci_test_groups.sh compiler
make test
make clean
```

After `make clean`, explicitly assert every known generated standard/test
header is gone and author-written native fixture headers remain. The complete
manual macOS workflow dispatch remains the pre-merge platform gate because it
also exercises universal archives, dSYM/provider restoration, and both native
library modes; Linux push jobs cover the prepared-tree producer, compiler
consumer, and sanitizer graph.

## Standard-library allocation audit focus

The semantic change is not safely covered by compiler fixtures alone. Current
source has many inferred C pseudo-constructor locals. In particular:

* async libuv requests/handles (`uv_fs_t`, `uv_write_t`, `uv_timer_t`,
  `uv_getaddrinfo_t`, `uv_connect_t`, `uv_shutdown_t`, `uv_signal_t`, pipes,
  TCP/process/loop objects) are commonly stored in owner records and survive a
  suspension; inference must not leave later C operations pointing at an
  automatic pre-copy local;
* `llhttp_t` and `llhttp_settings_t` are retained by the parser record;
* `uv_process_options_t` and the three-element `uv_stdio_container_t` are the
  intended automatic-allocation dogfood, but the returned `uv_spawn_config`
  currently outlives `os_spawn_config_new`, so its final ownership must be
  audited rather than inferred from the local construction site alone;
* `mco_runtime.new()` is a module-variable initializer and should retain its
  rooted owner semantics;
* inferred character buffers with compile-time counts may switch to automatic
  arrays, while buffers returned, stored, or borrowed asynchronously must remain
  owned explicitly;
* the normalized address and argv shim types disappear or move, so their
  replacement ownership and callback borrow intervals need the existing native
  behavior tests.

Audit each `.new()`/`.new_array()` use by actual lifetime and suspension points,
not by adding a blanket “always owned” workaround. This follows the draft's
purpose and the repository's supported trust model.
