# Function-entry ABI naming and generated-header audit

## Scope

Audit only. I inspected the dirty `feature/ffi-wrapup` checkout and did not edit
compiler/runtime/test implementation files. The required scope is the ABI
top-level function family:

```text
<mangled module>_\u2133_<function>
```

That stem is shared by public and local ordinary functions and by source-defined
foreign functions. Ordinary functions derive native, Lua-stack, and strict
roles from it; a foreign function has only its C-native role. Methods, nominal
statics, bound-method trampolines, lambdas, Interface artifacts, module
protocols, and module identities are separate symbol families and should not be
renamed mechanically as part of this rule.

## Executive findings

1. **The central source-spelling helper is on the right path.**
   `coder._function_prefix` now returns
   `mangle_qn(modname) .. "_\\u2133_" .. name`; `func_name`, `func_luaname`,
   `coder._func_strictname`, and `coder._foreign_func_name` all derive from it.
   The old `_source_private_identifier` hex encoder is gone and the
   public/local branches in those three ordinary-function helpers have become
   redundant.
2. **There is a critical C-source-name versus object-symbol-name distinction.**
   The generated C must spell `\u2133`, but GCC/Clang emit and native tools
   report the UTF-8 symbol `ℳ`. Exact `nm` assertions using
   `coder._foreign_func_name` therefore fail. More seriously, the generated
   traceback-name registry currently passes the C spelling through
   `c_string_literal`, which doubles the backslash and installs the literal key
   `"...\\u2133..."`; libbacktrace reports `"...ℳ..."`. Qualified Titan frame
   names will consequently fail to replace raw native symbols.
3. **Two existing provider-collision tests now assert behavior that this ABI boundary is
   specifically meant to remove.** `(a, b_c)` and `(a.b, c)` no longer share a
   function symbol. Flattened *module-prefix* checks and inventories of all the
   other symbol families must remain.
4. **The generated-header implementation is not yet integrated into the common
   output plan.** It has useful local ownership checks, but `.titan.h` is absent
   from standalone/provider output-vs-input collision validation, cleanup,
   ignores, and sanitizer snapshots. Three generated standard headers are now
   untracked in this checkout: `titan/coroutine.titan.h`,
   `titan/uv/uv.titan.h`, and `titan/http/http.titan.h`. I left them untouched.
5. **There is one concrete suffix inconsistency to resolve.** The design draft
   shows draft ABI-suffixed top-level Lua/strict names, while
   current code emits `_titanentry_lua` / `_titanentry_strict` after the new
   stem. The audit requirement mandates the common stem, so both satisfy that
   narrower statement, but the branch must choose one exact ABI spelling before
   tests/docs land. Choosing the draft spelling also requires updating the
   runtime traceback sentinel, which currently searches for `titanentry`.

## Compiler naming inventory

### Correct central path

In `titan-compiler/coder.lua`:

- `mangle_qn` remains the module-name flattener.
- `coder._function_prefix(modname, name)` is the one desired top-level
  module/member boundary.
- `func_name` appends `_titan` and is used by:
  - direct calls in `codecall`;
  - ordinary declarations/definitions and canonical closures in `codefuncdec`
    and `generate`;
  - dynamic/static imported function inventories and declarations;
  - `coder.external_symbols` and `coder.interface_external_symbols`.
- `func_luaname` and `coder._func_strictname` feed ordinary public/local closure
  construction and entry definitions.
- `coder._foreign_func_name`, `_foreign_reference_name`,
  `_foreign_function_signature`, `_code_foreign_function`, and the generated
  header path all use the same native name for foreign declarations, direct
  calls, address decay, callback assignment, inline definitions, and hidden
  out-of-line definitions.

The ignored `islocal` parameters on `func_name`, `func_luaname`, and
`_func_strictname` can now be removed, along with their caller arguments. They
must not grow a visibility-dependent naming branch again.

### Source-private helpers that still exist

- `_source_private_identifier` has correctly disappeared.
- `_source_private_prefix` no longer encodes hex; it now just joins a mangled
  owner and member. It is **not** a top-level function-entry helper anymore.
  Its remaining uses are `fname_prefix` for local nominal methods/statics and a
  generated-header guard. Rename it to describe those remaining roles or
  inline/split it so tests do not repeat the mistake currently present in
  `error_handling_spec.lua`.
- `_source_module_identity_name` also changed from hex to readable mangling.
  Keep its symbol in both source and recovered-interface inventories: provider
  identity is an independent generated family and can participate in
  cross-family collisions.

Local methods/statics still use the nominal/member families and remain subject
to their existing split ambiguity. The new top-level separator does not prove
those names injective.

### C spelling versus linkage spelling (blocking correctness issue)

A minimal C99 compile demonstrates the two representations:

```c
int foo_bar_\u2133_baz_titan(int x) { return x + 1; }
```

GNU `nm` and DWARF report:

```text
foo_bar_ℳ_baz_titan
```

The same distinction is expected with Clang/Mach-O (plus Darwin's conventional
leading underscore in `nm`). Keep separate concepts/helpers:

- **C identifier/string-token spelling**: `foo_bar_\u2133_baz_titan`, used in
  generated declarations, calls, and raw C string tokens whose compiler must
  interpret the UCN (for example the current `loadsym(..., "$NAME")`
  templates).
- **Linkage/tool spelling**: `foo_bar_ℳ_baz_titan`, used to compare `nm`, DWARF,
  libbacktrace, ASan, or other object-tool output.

Do not pass a UCN-bearing symbol through the ordinary `c_string_literal` when
the runtime value must equal the native linkage name. Current trace-name
initialization does exactly that at `tlcontext.names -> lua_setfield`: generated
C contains `"test_\\u2133_f_titan"`. Either emit the safe compiler-owned name
as a raw UCN-bearing C string token or convert the UCN boundary to its UTF-8
linkage spelling before ordinary literal escaping. Add a focused generated-C
assertion and retain the end-to-end `backtrace_spec.lua` / `so_trace_names_spec.lua`
gates; otherwise they will leak raw `_titan` symbols.

`spec/support/asan_generated_c_context.lua` parses symbol text generically and
does not hard-code ASCII, but it should gain a Unicode-symbol fixture so the
provider/object/shadow lookup contract is explicit.

## Provider collision machinery

### Must remain

The `titanc` preflight at the `mangled_owners` / `symbol_owners` tables remains
architecturally necessary:

- distinct logical modules such as `clash.a-b` and `clash.a.b` still flatten to
  the same module prefix;
- `_abi`, `_types`, `_init`, `luaopen_*`, source module identity, record/union
  statics, methods, bound Lua/strict entries, Interface bound entries, and
  nominal names do not acquire the new top-level separator;
- cross-family collisions such as `luaopen_<x>` versus another module's ABI
  symbol remain real;
- output/provider/input path checks and producer/native-binding checks are
  unrelated to function-name injection and must remain.

Accordingly, retain `coder.external_symbols`,
`coder.interface_external_symbols`, and the preflight across source modules,
selected static providers, dynamic contextual owners, and native bindings.
The following tests in `spec/coder/multi_module_libraries_spec.lua` remain
valid in intent:

- flattened module-prefix rejection (`clash.a-b` / `clash.a.b`);
- record-function/method/bound-entry collisions;
- Interface bound-entry collisions;
- module-protocol cross-family collisions.

The prefix-collision cases in
`spec/checker/static_compiled_modules_spec.lua` also remain valid.

### Can be simplified

The new separator proves top-level `(module, function)` injection after two
existing facts: logical function identifiers are ASCII and distinct within a
module, and colliding flattened module names are rejected separately. Thus:

- remove the old local-function hex encoder and all hex-specific tests/docs;
- remove visibility branches and `islocal` parameters from top-level naming;
- do not build or recover a special source-local function-name inventory from
  static metadata (locals are not metadata); the shared formula is sufficient;
- do not retain a collision rejection whose only witness is `(a, b_c)` versus
  `(a.b, c)`.

Keeping local top-level native entries in `external_symbols` is harmless and
keeps the inventory complete, but no separate local-only collision mechanism is
needed. Their names cannot collide with another generated top-level function
family once module-prefix uniqueness and checker duplicate errors hold. Do not
apply that conclusion to nominal methods/statics or other families.

### Tests whose expected outcome must change

In `spec/coder/multi_module_libraries_spec.lua`:

- `rejects module/member boundary symbol collisions before code generation`
  must become a successful compile/run (and preferably assert the two distinct
  UCN C spellings/linkage symbols).
- `preflights symbols from producer-dynamic contextual owners` currently
  expects `a.b_c` and `a_b.c` to collide; it must instead prove that recovered
  contextual-owner inventories use the new distinct names and link.
- `keeps source-private symbols injective across module boundaries` should stay
  as a positive case but assert readable UCN names and absence of `titan_source_`
  hex names.

## Test expectation inventory

The following specs contain exact old top-level native/Lua spellings or helper
logic and need conversion to the common naming helper/source spelling:

- `spec/coder/c_ffi_spec.lua` (`native_body` helper);
- `spec/coder/c_ffi_operators_spec.lua` (`native_body` helper);
- `spec/coder/coder_spec.lua`;
- `spec/coder/closure_adjustment_wrappers_spec.lua` (the ordinary
  `forwarded*` bodies; consumer-local adapter names are a separate family);
- `spec/coder/closures_spec.lua`;
- `spec/coder/dense_arrays_spec.lua`;
- `spec/coder/first_class_functions_spec.lua`;
- `spec/coder/flexible_returns_spec.lua`;
- `spec/coder/flexible_returns_finally_spec.lua`;
- `spec/coder/interfaces_spec.lua` (ordinary top-level helpers only; method and
  Interface artifact expectations remain their own families);
- `spec/coder/named_arguments_spec.lua`;
- `spec/coder/variadic_spec.lua`;
- `spec/coder/multi_module_path_runtime_spec.lua`;
- `spec/coder/error_handling_spec.lua` (replace the erroneous
  `_source_private_prefix(... ) .. "_titan"` expectation with the top-level
  function helper).

Also exercise all six meaningful combinations directly in the new topical
coder coverage: public native/Lua/strict, local native/Lua/strict when used as a
value, local native-only when not used as a value, and foreign native-only.
Assert no `titan_source_<hex>` spelling anywhere.

If the ABI-suffixed `_lua` / `_strict` names from the design draft are
adopted, additionally update:

- top-level entry assertions in the files above;
- `spec/coder/backtrace_spec.lua`, `multi_module_libraries_spec.lua`, and their
  comments/assertions that search for `titanentry`;
- `titan-runtime/titan.c`'s `TITAN_ENTRY_TAG` and both native-frame and
  `lua_CFunction` sentinel recognition;
- `doc/implementation/error-handling.md`, `codegen-overview.md`,
  `lua-interop-internals.md`, and `driver.md`.

Do not accidentally rename method/static/lambda/adjustment-wrapper sentinels
unless the ABI decision explicitly expands to those families; the runtime may
need to recognize both exact entry-family tags.

## Standard callback and native-symbol assertions

The source-defined production callbacks now belong to three logical objects:

- `titan.coroutine`: `coro_entry_trampoline`;
- `titan.uv`: the 13 `UV_FOREIGN_CALLBACKS` in
  `spec/libuv_build_spec.lua`;
- `titan.http`: the eight `HTTP_FOREIGN_CALLBACKS`.

Required C-source stems are respectively
`titan_coroutine_\u2133_*`, `titan_uv_\u2133_*`, and
`titan_http_\u2133_*`; `nm` sees `titan_*_ℳ_*`.

Current coverage gaps/fixes:

- `spec/coder/c_ffi_tag_names_spec.lua` checks generated C via
  `coder._foreign_func_name`; keep it as the C-source-spelling assertion.
- `spec/libuv_build_spec.lua` passes that same C spelling to exact
  `nm_has_symbol`, which is wrong. Normalize expected names to linkage spelling
  (while retaining Darwin underscore handling).
- Extend the native build assertion to the coroutine and HTTP logical objects,
  not only `titan/uv/uv.o`, and check exact new definitions plus absence of
  `titan_coro_entry`, `titan_uvshim_*`, and `titan_httpshim_*` callback entries.
- Keep the direct unresolved libuv/host-call checks separate; those names are
  external C library symbols and do not use the Titan separator.
- `spec/support/ci_libuv_mode_smoke.sh`'s current `nm` parsers are generic and
  its libuv/OpenSSL/LPegLabel symbol tests are unaffected. If it becomes the
  production callback-symbol gate, use linkage spelling there too.

## Generated `*.titan.h` integration

### What is already sound

`driver.plan_foreign_header`, `validate_foreign_header_plan`,
`write_foreign_header_plan`, and `prepare_foreign_headers` implement useful
pieces of the intended lifecycle:

- canonical source-adjacent `.titan.h` derivation from `native_output`;
- one plan for a flat source or canonical folder main, never a contributor;
- all headers prepared before the first CLI source-object compile;
- detection of two logical source modules sharing one lexical absolute header
  path;
- refusal to overwrite a non-banner file when a header is required;
- replacement of a banner-owned header;
- removal of a banner-owned stale header when the module loses its final
  foreign function;
- no header for compiled dependencies and no publication/install transaction.

Keep banner-bounded ownership. A broad `rm *.titan.h` is not acceptable.

### Concrete bugs/gaps

1. **Wrong suffix in loader provenance.** `driver.defaultloader` (new source and
   cached source paths) and `driver.tableloader` still derive `... .h`, while
   the actual artifact is `... .titan.h`. The CLI preparation pass later
   overwrites AST edges, masking this for ordinary `titanc`, but direct
   `driver.compile`/tableloader/test callers can emit includes for the wrong
   author header. Use one canonical path helper and store/reuse the finalized
   native-output path.
2. **Not in the unified output collision plan.** `titanc` builds
   `source_outputs` with only `.c/.o`; `validate_program_output_paths` knows
   only those, the entrypoint/object/executable/dSYM, and native inputs.
   `validate_provider_output_paths` likewise knows the provider pair/dSYM and
   native inputs. Header plans are created only after those checks and after
   shim planning. Consequently headers are not checked against C/object,
   executable, provider, shim, or native-input aliases/hierarchy, nor through
   the existing normalized/physical/same-file policy.
3. **Leaf type/alias checks are weaker than other outputs.** Header validation
   reads contents but does not apply the regular-nonlink leaf checks used by
   program/provider outputs. Directories and symlink/hardlink aliases can fail
   late or bypass the common diagnostic model.
4. **No tests currently mention `.titan.h`.** The implementation therefore has
   no pinned flat/folder/external-tree path, ownership, collision, stale
   retirement, dependency order, or cleanup behavior.
5. **The third `coder.generate` header return is currently redundant with the
   separate plan/regeneration path and is ignored by `driver.compile`.** Pick
   one owner for header rendering rather than letting the two paths drift.

Recommended orchestration: plan every source module's canonical header
operation immediately after the complete checked source graph is known; resolve
source-header edges; add every managed header destination to the same
output/input collision set (including stale deletion destinations); validate
all leaves and ownership; only then write/remove headers and compile objects.
This preserves the intended trusted-project model while matching the compiler's
existing output invariants—no speculative packaging or compatibility layer is
needed.

### Required header tests

Add focused driver/coder cases for:

- flat, folder-main, contributor-none, and external-`--tree` paths;
- consumer-before-producer generation and direct source dependency includes;
- generated C including its exact companion `.titan.h`;
- reserved user file refusal before any C/object/provider change;
- banner-owned replacement and stale removal;
- preservation of a non-banner file when no header is owned;
- duplicate/aliased header destinations and header-vs-native-input/output
  collisions under the same path policy;
- no header in serialized types, `.titan.meta`, provider key sets, shims,
  installed SDK, or stdlib publication stage.

## Cleanup, build, and external-script inventory

- **`Makefile clean`:** add only the exact three standard generated headers
  (preferably an explicit variable) and extend `spec/libuv_build_spec.lua`'s
  exact-cleanup assertions. Do not add `titan/**/*.titan.h` or another broad
  glob.
- **`.gitignore`:** add exact entries for the same three checkout-generated
  standard headers; do not globally ignore `*.titan.h`.
- **`spec/support/clean_generated_test_artifacts.sh`:** extend cleanup with the
  exact generated banner as the ownership proof. Preserve author-written
  headers. In-memory helper builds can create `test.titan.h` without a physical
  `test.titan`, so a same-stem-source test alone is insufficient; either clean
  that exact helper artifact in `spec/support/helpers.lua`/owning specs or use a
  narrowly rooted banner scan.
- **Individual coder specs:** `spec/coder/c_ffi_tag_names_spec.lua` currently
  removes `test.c/.o/.so` but not `test.titan.h`; new foreign-function coder
  specs must clean their exact banner-owned headers too.
- **Sanitizer snapshot:** `spec/support/asan_generated_c_context.lua` and
  `ci_asan_generated_c_context.lua` save only generated `.c/.o` pairs and the
  compile argv. Generated C now includes absolute generated-header paths, and
  inline foreign bodies can affect object bytes. Snapshot the exact generated
  header closure and make shadow compilation consume the preserved copy (with
  path handling that does not silently change semantics), then extend
  `spec/asan_generated_c_context_spec.lua`, the Makefile snapshot contract, and
  `.github/workflows/ci.yml` assertions.
- **Publication/snapshot scripts:** `scripts/stdlib_installer.lua` and
  `spec/support/ci_stdlib_snapshot.sh` should continue to exclude generated
  headers because they are neither installed nor part of the coordinated
  standard image. `spec/rockspec_spec.lua` / `stdlib_installer_spec.lua` should
  assert that exclusion and the reduced installed SDK header set.
- **Production smoke scripts:** no existing symbol parser besides the
  `libuv_build_spec` exact callback check currently assumes old Titan function
  names. Generic `nm`/`readelf` consumers remain valid, but use the linkage
  spelling if an exact callback assertion is added.

## Documentation inventory

Update the following naming references/examples:

- `doc/implementation/codegen-overview.md`: generated example, symbol-family
  table, external-symbol preflight rationale, dynamic import declarations and
  `loadsym` strings, and ABI rationale;
- `doc/implementation/codegen-constructs.md`: `dep_mk_titan` and
  `test_two_titan` examples;
- `doc/implementation/lua-interop-internals.md`: ordinary top-level Lua/native
  examples and, depending on the suffix decision, entry-sentinel prose;
- `doc/implementation/values-and-gc.md` and
  `variadic-parameters.md`: native signature examples;
- `doc/implementation/multi-module-libraries.md` and
  `doc/language/multi-module-libraries.md`: delete the now-false `(a,b_c)` /
  `(a.b,c)` rejection; explain that flattened module and other-family checks
  remain;
- `doc/implementation/source-import-visibility.md`: replace private
  hex/injective-name implications and the claim that public entries retain the
  old ABI name;
- `doc/implementation/error-handling.md` and `driver.md`: UCN/linkage display
  names and the exact entry sentinel if suffixes change.

Update generated-header/artifact documentation in:

- the new language `foreign-functions.md` chapter (already mostly states the
  intended path/naming contract) and a matching implementation chapter/index
  link;
- `doc/language/modules.md`, `folder-modules.md`, and
  `doc/implementation/folder-modules.md` artifact tables (conditional
  `.titan.h`, canonical main only, contributor none);
- `doc/implementation/driver.md` (planning order, collision/ownership/stale
  removal, and no publication/install role);
- `doc/implementation/ffi-internals.md` (distinguish imported C headers, C-type
  origin headers, and direct generated source-collaboration headers);
- `README.md` generated-output and cleanup sections;
- `AGENTS.md` artifact/cleanup/sanitizer-snapshot invariants.

The same README/AGENTS/manual pass must also remove stale runtime-member/header
statements (`titan_uv.o`, `titan/{coro,uv}.h`) and update active paths where the
broader ABI work already changed them, but that is wider than the naming
mechanism itself.

## Suggested implementation order

1. Resolve the exact Lua/strict suffix decision and define one top-level naming
   API plus one explicit linkage/tool spelling conversion.
2. Fix trace-name key emission, then update direct generated-C name assertions
   and backtrace tests.
3. Invert the two obsolete boundary-collision tests while retaining all
   module/nominal/protocol collision gates.
4. Normalize callback `nm` expectations and add coroutine/HTTP symbol coverage.
5. Centralize `.titan.h` path planning, integrate it into output preflight, and
   add lifecycle/collision tests.
6. Add exact/bounded cleanup, ignores, and sanitizer header snapshots.
7. Update manuals, README, AGENTS, and structural build/packaging assertions.
