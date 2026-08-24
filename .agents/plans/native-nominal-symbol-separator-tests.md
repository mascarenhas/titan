# Native nominal-symbol separator: tests, documentation, and ABI audit

## Scope and conclusion

This is an audit of `feature/ffi-wrapup` at `6976f13`. I did not edit compiler,
runtime, documentation, or test implementation. The current branch has the
top-level ABI naming boundary

```text
<mangled module>_\u2133_<top-level function>
```

but every record/union callable and nominal Lua metamethod still flattens the
module/nominal/member structure with underscores. Extending the scheme should
make the hierarchy explicit:

```text
M                         = mangle(module)
nominal stem              = M_\u2133_N
record/union member stem  = M_\u2133_N_\u2131_X
```

where `N` is the record/union source name and `X` is a method/static name.
Generated C must contain the C99 UCN spellings `\u2133` and `\u2131`; ELF,
Mach-O, DWARF, libbacktrace, `nm`, and `dlsym` see UTF-8 `ℳ` and `ℱ`.

The change is a native symbol-contract change even though callable signatures,
serialized `Type.Record`/`Type.Union` descriptors, module-state slots, and the
static metadata container do not change. If it lands before the associated
`feature/ffi-wrapup` ABI boundary is merged/published, it should be folded into
that boundary and its rationale expanded. If a provider using the old naming
contract has already become a supported artifact, the marker must advance
again; an old and new provider can serialize identical types while exporting
different method/static symbols.

## Naming model that tests should pin

For module `foo.bar`, record/union `Thing`, and member `work`, the intended C
source families are:

| Role | C source spelling |
|---|---|
| top-level native | `foo_bar_\u2133_work_titan` |
| nominal static native | `foo_bar_\u2133_Thing_\u2131_work_titanstatic` |
| static Lua entry | `foo_bar_\u2133_Thing_\u2131_work_titanentry_luastatic` |
| static strict entry | `foo_bar_\u2133_Thing_\u2131_work_titanentry_strictstatic` |
| method native | `foo_bar_\u2133_Thing_\u2131_work_titanmethod` |
| method Lua entry | `foo_bar_\u2133_Thing_\u2131_work_titanentry_luamethod` |
| bound native | `foo_bar_\u2133_Thing_\u2131_work_boundmethod` |
| bound Lua | `foo_bar_\u2133_Thing_\u2131_work_titanentry_boundlua` |
| bound strict | `foo_bar_\u2133_Thing_\u2131_work_titanentry_boundstrict` |
| record/union lookup helper | `__index_foo_bar_\u2133_Thing` |
| record/union write helper | `__newindex_foo_bar_\u2133_Thing` |

The metamethod helpers are file-local rather than provider ABI entries, but they
must consume the same separated nominal stem. Otherwise generated C keeps a
second, inconsistent nominal encoding. There is no source member after the
nominal in those helper names, so `\u2131` is not needed unless the design
instead chooses to model `__index`/`__newindex` as synthetic nominal members.
Whichever spelling is chosen should be asserted literally.

Two independent collision witnesses are required; covering only one does not
prove the tuple encoding:

1. **module/nominal boundary**
   - module `boundary.root`, nominal `child_Thing`, member `run`;
   - module `boundary.root.child`, nominal `Thing`, member `run`.
2. **nominal/member boundary in one module**
   - nominal `Left_Right`, member `read`;
   - nominal `Left`, member `Right_read`.

With both separators these become distinct even though the old underscore-only
stems coincide. Keep the existing control that rejects genuinely colliding
*mangled module prefixes*, e.g. `clash.a-b` versus `clash.a.b`; the new member
separators do not make module mangling itself injective.

## Current implementation surfaces affected

### Central naming and linkage conversion

In `titan-compiler/coder.lua`:

- `mangle_qn` is the low-level `.`/`-` flattener.
- `_function_prefix` already owns the module/top-level `\u2133` boundary.
- `fname_prefix` currently returns either
  `_source_private_prefix(typ.fqtn, typ.name)` or
  `mangle_qn(typ.fqtn) .. "_" .. typ.name`. It feeds every record/union
  static, method, bound-method role **and every Interface method artifact**.
- `static_name`, `static_luaname`, `_static_strictname`, `method_name`,
  `method_luaname`, `bound_method_name`, `bound_method_luaname`, and
  `_bound_method_strictname` all inherit that old stem.
- `_linkage_symbol_name` currently converts only `\u2133` to UTF-8 `ℳ`. It must
  also convert `\u2131` to `ℱ`; a method backtrace or an exact `nm` comparison
  otherwise uses a C spelling that cannot match the object symbol.

A minimal C99 probe confirmed the tool boundary:

```text
C:  demo_\u2133_Record_\u2131_method_titanmethod
nm: demo_ℳ_Record_ℱ_method_titanmethod
```

Keep source-spelling and linkage-spelling assertions separate. Do not compare
`nm` output directly to a UCN-bearing C identifier helper.

### Source and recovered-interface inventories

`coder.external_symbols` inventories source AST entries. It includes:

- public and local record/union static native entries;
- method native plus bound native/Lua/strict entries;
- synthesized record `new` and union variant constructors because they are
  ordinary `Ast.TopLevelStatic` nodes.

`coder.interface_external_symbols` reconstructs the public subset from DSO or
archive type metadata. It must derive exactly the same new names for public
record and union statics/methods. Locals remain source-only and correctly do not
appear in serialized interfaces. This parity matters to `titanc` preflight for
source modules, selected static membership, direct DSOs, and producer-dynamic
contextual nominal owners.

The embedded `.titan.meta`/`__titanmeta` payload does **not** store native member
names. It continues to store the module ABI string and serialized public type;
`interface_external_symbols` derives the linkage inventory from that type. No
metadata schema or key-order change is warranted.

### Dynamic and static call paths

All three existing native binding modes consume these helpers:

- source/static `direct`: C `extern` plus a direct UCN identifier;
- DSO `handle`: `loadsym` of the exact selected provider handle;
- transitive/contextual `global`: `loadglobalsym` from the promoted namespace.

Bound method values additionally recover the exported bound native, bound Lua,
and bound strict entries. A DSO test that calls only an unbound method through a
direct handle is insufficient: it does not exercise the global path or all
three first-class roles.

Trace registration records method/static native names and bound native/strict
names. Its `lua_setfield` key goes through `_linkage_symbol_name`, so method,
static, and bound backtraces are direct coverage of the new `\u2131` conversion.

### Metamethods that bypass `fname_prefix`

`coderecorddec` currently substitutes `mangle_qn(node._type.name)` independently
at all three `RECNAME` sites, including both the nonempty- and empty-record
templates. `_codeuniondec` does the same at its two `UNIONNAME` sites. These are
the easy-to-miss `__index_*` and `__newindex_*` entries explicitly in scope.

Interface metatable helpers independently use
`mangle_qn(interface.name)` for `__index_interface_*` and
`__newindex_interface_*`; see the Interface scope decision below.

## Existing tests and expected disposition

### Collision/preflight coverage

`spec/coder/multi_module_libraries_spec.lua` already has the main inventory:

- `rejects mangled symbol collisions before code generation`: retain unchanged;
  it tests actual module-prefix collision (`clash.a-b` / `clash.a.b`).
- `keeps source-private symbols injective across module boundaries`: retain and
  add nominal-local coverage rather than reviving a private hex scheme.
- `keeps module/member boundary symbols injective`: retain for top-level
  `\u2133`.
- `preflights symbols from producer-dynamic contextual owners`: retain; enhance
  it with a nominal method/static so recovered owner inventory uses both
  separators.
- `preflights record-function and bound-method symbols`: its current rejection
  is precisely the module/nominal ambiguity that the extended scheme removes.
  Invert it to successful build/run and assert the two distinct symbol stems.
- `preflights all three exported Interface bound-method symbols`: do not change
  accidentally; its outcome depends on the explicit Interface decision below.
- `preflights cross-family protocol symbols from source dependencies`: retain;
  module protocol names remain outside the new member family.

The mangled-prefix controls in
`spec/checker/static_compiled_modules_spec.lua` (`dynamic.a-b`/`dynamic.a_b` and
source/carried membership) also remain valid.

### Exact old nominal spellings

The following assertions currently spell the underscore-only family and must be
updated to literal UCN source names (or deliberately retained only if they cover
an excluded Interface family):

- `spec/coder/closures_spec.lua`: `Counter.get` native and bound-Lua entries;
- `spec/coder/dense_arrays_spec.lua`: `Holder.new` static;
- `spec/coder/interfaces_spec.lua`: concrete method calls and Interface artifact
  inventory;
- `spec/coder/unions_spec.lua`: source/recovered constructor inventory;
- `spec/coder/so_import_spec.lua`: handle/global record static, method, and bound
  entries through direct and re-exported aliases;
- `spec/coder/static_dynamic_facade_spec.lua`: handle/global `Box.make` and
  `Box:add`;
- `spec/coder/multi_module_libraries_spec.lua`: contextual
  `shape.provider.Foo:plus` and the current collision expectations;
- `spec/coder/folder_modules_spec.lua`: Interface bound symbol, subject to the
  Interface decision.

`spec/coder/coder_spec.lua` already runs public/local record statics and methods,
and has `calls and binds functions on records with underscored names`, but it
does not assert native spellings or create either ambiguous tuple. It is useful
runtime coverage, not a naming proof.

`spec/coder/backtrace_spec.lua` already requires a method frame to display as
`test.Point:bad` with no raw `_titan` leak. This becomes an important end-to-end
`ℳ`+`ℱ` linkage-key test. `spec/coder/so_trace_names_spec.lua` currently covers
only top-level functions; add a nominal DSO frame there or in the existing DSO
method test.

## Proposed exhaustive test matrix

### 1. Focused naming/codegen test

Prefer a topical `spec/coder/native_symbol_names_spec.lua` (or one tightly
bounded block in the existing coder specs) that generates one module containing:

- a nonempty record and an empty record;
- a union;
- public and local explicit statics;
- synthesized record `new` and union variant constructors;
- public and local methods;
- a bound use of each method so bound native/Lua/strict roles are emitted.

Assert the exact C-source spellings and counts for every role in the table
above. Also assert:

- record nonempty, record empty, and union `__index`/`__newindex` use the
  separated nominal stem;
- the old `<mangled-fqtn>_<member>_*` spellings are absent;
- the generated C contains textual `\u2133`/`\u2131`, not literal UTF-8;
- `_linkage_symbol_name` converts a string containing both boundaries to exact
  UTF-8 `ℳ`/`ℱ` and leaves ordinary text unchanged;
- `nm` on the compiled object contains the UTF-8 linkage names and no literal
  `\u2133`/`\u2131` text.

Add the same-module `Left_Right.read` versus `Left.Right_read` pair for both a
method and a static. Successful C compilation and distinct runtime results
prove the `\u2131` boundary; a test with only `boundary.root`/child proves only
`\u2133`.

A small pure validation assertion should pin the proof premise that actual
U+2133/U+2131 cannot occur in a Titan identifier or logical module name. It may
reuse existing lexer/module-name validation rather than add a new policy.

### 2. Co-generated source/provider runtime

Invert and strengthen
`preflights record-function and bound-method symbols`:

- `record_boundary.root` owns `child_Thing`;
- `record_boundary.root.child` owns `Thing`;
- give both the same static name and method name, call each directly and as a
  bound value, and return distinguishable results;
- add the analogous union constructor/static and method pair;
- compile both roots into the one common-prefix `.so`/`.a` pair;
- require both logical shims and exercise static calls, Titan method calls,
  bound calls, and Lua `obj:method` lookup.

Assert C source names for both sides and, if the test already has a portable
symbol helper, exact UTF-8 provider symbols. This covers source AST preflight,
cross-object linking inside one provider, both record and union generation, and
runtime metatable dispatch.

Add local nominal statics/methods behind exported wrappers. Public-only success
would not exercise the `typ.islocal` branch that currently routes through
`_source_private_prefix`.

### 3. DSO-only providers

Extend `spec/coder/so_import_spec.lua` with two separately built `.so`-only
owners whose old names collide:

- module `dso_boundary.root`, nominal `child_Box`;
- module `dso_boundary.root.child`, nominal `Box`;
- and the same-module `Left_Right` / `Left.Right_*` member ambiguity in one
  owner.

Exercise:

1. direct handle-scoped static and method calls;
2. a bound method value (forcing recovery of bound native, Lua, and strict
   entries);
3. a genuine Lua `obj:method` call through the provider's nominal metatable;
4. a re-exported nominal alias whose consumer does **not** open the owner again,
   forcing `loadglobalsym` for method/static/bound roles;
5. equivalent union constructor/static and method calls.

Inspect generated consumer C for exact `loadsym` and `loadglobalsym` UCN string
literals, including bound strict (existing assertions stop at bound Lua in some
paths). Inspect each DSO's `nm` output for the corresponding `ℳ`/`ℱ` exports.
Runtime results must distinguish both providers so accidental ELF global
interposition cannot pass.

Add a raising DSO method or static to `so_trace_names_spec.lua` and require the
qualified `module.Record:method` / `module.Record.static` frame with no raw
Unicode native name. That proves the linkage-key conversion after `dlopen`, not
just direct linkage.

### 4. Static archive-backed providers

Add a companion case in `spec/coder/static_compiled_modules_spec.lua` or
`multi_module_libraries_spec.lua`:

- build the two ambiguous owners as separate paired providers;
- remove/hide their DSOs and sources so `--static` must select `.a` metadata;
- compile a standalone consumer importing both;
- call record and union statics, methods, and bound method values;
- run the executable and assert distinct results.

This one case simultaneously proves:

- archive metadata ABI/type recovery;
- `interface_external_symbols` reconstructed-name parity;
- preflight no longer reports the obsolete nominal collision;
- generated direct `extern` references use both UCN separators;
- the final static link resolves the provider's UTF-8 symbols.

Inspect archive `nm` output for exact `ℳ`/`ℱ` symbols and confirm the metadata
key set/type strings are otherwise unchanged. Keep
`static_dynamic_facade_spec.lua` as the producer-dynamic mixed case and update
its exact `Box.make`/`Box:add` strings; ideally add an ambiguous peer so the
runtime result would expose a wrong `loadglobalsym` binding.

### 5. Source/recovered inventory parity

Strengthen the current constructor-only assertion in
`spec/coder/unions_spec.lua` into a small table-driven inventory test containing
one public record and one public union, each with:

- synthesized constructor/variant;
- explicit static;
- method plus all three exported bound roles.

For every expected symbol, find the same exact C spelling and owner description
in both `coder.external_symbols` and `coder.interface_external_symbols`.
Separately assert local statics/methods occur only in the source inventory.
This is faster and more diagnostic than relying only on a linker failure.

### 6. Backtrace and metamethod behavior

Retain the existing record-method backtrace test and add a nominal static frame.
A bound-method raising path is also valuable because its trace table registers
bound native/strict symbols independently. Require qualified Titan display
names and absence of raw `_titan`, `ℳ`, `ℱ`, and `titanentry` leakage.

At runtime, use Lua to read/write a nonempty record field, call a record method,
call a union method, reject a union write, and provoke an empty-record missing
member. These observable checks complement the literal generated-C assertions
for all metamethod templates.

### 7. ABI rejection control

Generic ABI mismatch coverage already exists in `spec/abi_spec.lua`, DSO
rehydration tests, and static protocol mismatch tests. Keep the ordering
invariant: reject the predecessor ABI before decoding types or trying a renamed
method/static symbol. If the ABI remains unchanged because this is folded into
the unreleased branch, update the feature rationale rather than inventing a
metadata migration test. If the marker advances, add one old-name provider
fixture proving the diagnostic is an ABI mismatch, not a late missing-symbol
error.

## Interface scope must be explicit

`fname_prefix` is shared by record/union methods and Interface method artifacts.
A mechanical change there will rename Interface ordinary Lua entries and the
three exported bound-method roles, even though the requested boundary names
record/union methods/statics. Interface metatable helpers have a separate old
flattened stem as well.

Choose and pin one of these policies:

1. **Record/union-only (literal requested scope):** split the naming helpers;
   preserve Interface symbols and keep
   `preflights all three exported Interface bound-method symbols` as a rejection.
   The Interface exact assertions in `interfaces_spec.lua` and
   `folder_modules_spec.lua` remain old by design.
2. **All nominal callable owners:** give Interface methods the same
   `M_\u2133_I_\u2131_method` stem, update Interface `__index`/`__newindex`
   helpers, invert the Interface boundary collision test, update source/recovered
   Interface inventory assertions, DSO/archive bound-Interface tests, and the
   ABI discussion in `doc/implementation/interfaces.md`.

Do not let helper reuse decide this accidentally. Interfaces export only bound
native/Lua/strict roles, but those are still provider ABI symbols.

## Documentation and ABI metadata inventory

### Exact naming examples/formulas

Update these current underscore-only nominal examples:

- `doc/implementation/codegen-overview.md` (symbol-family paragraph and method/
  static examples);
- `doc/implementation/codegen-constructs.md` (`Point.getx` call and naming
  formula);
- `doc/implementation/lua-interop-internals.md` (static/method entry overview,
  `interop.Point.move`, and record `__index`/`__newindex` examples).

Explain both C-source UCN and UTF-8 linkage spellings. The formulas should use a
split canonical owner `(module, nominal leaf)`, not imply that flattening the
whole FQTN remains safe.

### ABI rationale

Expand the current “top-level separator” wording to cover the complete native
entry hierarchy in:

- `titan-runtime/titan.h` ABI rationale (currently mentions only
  callback relocation and omits even the top-level name change);
- `AGENTS.md` current ABI summary and coder ABI history;
- `README.md` active ABI summary;
- `doc/language/foreign-functions.md` native-name/ABI section;
- `doc/implementation/foreign-functions.md` native-name/ABI section;
- `doc/language/multi-module-libraries.md` compiled compatibility;
- `doc/implementation/multi-module-libraries.md` ABI history;
- `doc/implementation/source-import-visibility.md` source-local native entries;
- `doc/implementation/error-handling.md` ABI history and linkage/display-name
  explanation;
- `doc/implementation/unions.md` current ABI summary;
- `AGENTS.md` project-context ABI invariant.

The language and implementation manuals should state that this ABI boundary
changes native names while retaining the existing serialized layouts. No new manual chapter
is needed.

### Metadata/version constants

If folded into the same unreleased ABI boundary, leave these values unchanged:

- `driver.TITAN_ABI_VERSION` and the matching `TITAN_ABI_VERSION` in `titan.h`;
- the compiler/stdlib release and derived library-layout constants;
- the Makefile/workflow ABI value and active versioned `TITAN_PATH` override;
- the canonical library and compiler-data paths; and
- static metadata ABI fixtures.

Only the textual rationale and symbol expectations change. The stdlib completion
stamp already depends on coder/compiler inputs, so a current installation must
be rebuilt; do not add cross-ABI or old-name compatibility aliases. If the
boundary is already supported/published, all of those coordinated values must instead move
together to the next ABI.

## Suggested validation order

1. Focused source-spelling/inventory/metamethod test.
2. Inverted source-provider collision case.
3. `so_import_spec.lua`, `so_trace_names_spec.lua`, and
   `static_dynamic_facade_spec.lua` nominal cases.
4. Archive-backed static consumer case.
5. `backtrace_spec.lua`, `unions_spec.lua`, and (after the scope decision)
   `interfaces_spec.lua`.
6. `abi_spec.lua` and static protocol mismatch coverage.
7. Complete compiler group, optimized standard-provider rebuild/runtime suite,
   and the required macOS dispatch. macOS is important because Mach-O `nm` adds
   its conventional leading underscore while preserving UTF-8 `ℳ`/`ℱ`.

The highest-risk omissions are the independent nominal/member collision,
`_linkage_symbol_name` handling of `\u2131`, empty-record and union metamethod
templates, source-local nominal entries, transitive `loadglobalsym`, and the
Interface helper-sharing decision.
