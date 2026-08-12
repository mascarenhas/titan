# Native nominal symbol separator audit

Audit baseline: `6976f13`, before the nominal-separator implementation. Status:
the findings below were implemented on `feature/ffi-wrapup`; descriptions of
what “currently” happens refer to that audited baseline.

## Finding

`feature/ffi-wrapup` has applied the required module/member separator only to
ordinary and source-foreign top-level functions.  Nominal callables and nominal
Lua metamethod helpers still use underscore-only flattening, so they remain
ambiguous.

The consistent target grammar should be:

```text
module callable:  <mangled-module>_\u2133_<member><role-suffix>
nominal callable: <mangled-module>_\u2133_<owner>_\u2131_<member><role-suffix>
nominal meta:     <mangled-module>_\u2133_<owner>_\u2131_<meta-role>
```

Here `\u2133` is U+2133 SCRIPT CAPITAL M (`ℳ` in ELF/Mach-O/DWARF tool
output) and `\u2131` is U+2131 SCRIPT CAPITAL F (`ℱ`).  Neither can occur in a
Titan name: `lexer.lua:166-168` limits identifiers to ASCII letters,
underscores, and digits.  Keep C source in UCN form and convert both UCNs to
UTF-8 wherever a string is compared with a linkage/tool name.

A generated sample currently demonstrates the split:

```text
pkg_sample_\u2133_top_titan             # already correct
pkg_sample_Box_get_titanmethod          # ambiguous
pkg_sample_Box_new_titanstatic          # ambiguous constructor
__index_pkg_sample_Box                  # ambiguous and reserved C spelling
```

The nominal forms should instead begin
`pkg_sample_\u2133_Box_\u2131_get...`,
`pkg_sample_\u2133_Box_\u2131_new...`, and
`pkg_sample_\u2133_Box_\u2131_index...` respectively.

## Exact `coder.lua` naming surface

### Top-level module functions (already centralized)

* `mangle_qn` and `modprefix` (`209-211`, `295-297`) flatten only the logical
  module.
* `_function_prefix` (`299-303`) inserts `"\\u2133_"`; `func_name`,
  `func_luaname`, `_func_strictname` (`311-334`) append the native/Lua/strict
  roles. `_foreign_func_name` and `_foreign_reference_name` (`315-324`) reuse
  the native role.
* Consumers are `external_symbols` / `interface_external_symbols` (`350-479`),
  direct calls (`10221-10276`), foreign calls/references (`8774-8843`,
  `15583-15586`), foreign signatures/header bodies (`15787-15812`,
  `17582-17715`), declaration emission (`15823-16020`), closure initialization
  (`17898-17964`), and dynamic/static import declaration and lookup
  (`16857-16934`).  These should continue to go through this one family.

### Record/union statics, constructors, and methods (must change)

The single choke point is `fname_prefix` (`233-238`).  Its public path emits
`mangle_qn(typ.fqtn) .. "_" .. typ.name`; its local path calls
`_source_private_prefix` (`222-227`), which currently emits the same spelling.
In both cases `typ.fqtn` already contains module and owner.  Every nominal
function family derives from it:

* statics: `static_name`, `static_luaname`, `_static_strictname`
  (`240-246`, `336-338`);
* methods: `method_name`, `method_luaname` (`248-254`);
* first-class bound methods: `bound_method_name`, `bound_method_luaname`,
  `_bound_method_strictname` (`256-270`);
* Interface method/bound artifacts also use it (`273-293`).

Replace/split `fname_prefix` so **both public and local** paths parse
`typ.fqtn` as `<module>.<owner>` and emit
`_function_prefix(module, owner) .. "_\u2131_" .. typ.name`.  Do not leave
local nominal callables on `_source_private_prefix`.  This
automatically covers record `new`, union variant constructors, and all explicit
record/union statics: parser-synthesized constructors are ordinary
`Ast.TopLevelStatic` nodes (`parser.lua:456-474`, `487-520`) and reach exactly
`static_*`; no constructor-only naming branch is needed.

Important downstream call sites to preserve are:

* preflight inventories (`367-399`, `425-477`);
* Interface adapter exact-method dispatch (`5142`, `5665-5677`, `18101`);
* direct static/method calls and cross-module registration (`10238-10258`,
  `10337-10359`);
* declaration/trace generation (`15841-15855`);
* bound trampoline definition and bound-value construction (`16091-16213`,
  `16341-16429`);
* dynamic `extern`/`loadsym`/`loadglobalsym` recovery (`16864-16934`);
* record/union Lua method maps (`16999-17010`, `17129-17148`);
* closure installation for statics (`17973-18021`).

Keep the existing role suffixes (`_titanstatic`,
`_titanentry_{lua,strict}static`, `_titanmethod`,
`_titanentry_luamethod`, `_boundmethod`,
`_titanentry_bound{lua,strict}`); the requested change is the two structural
boundaries, not a redesign of entry roles.

Interface owners are nominal/type-only too and currently share
`fname_prefix`.  The safest consistent result is to give their method artifacts
the same two separators.  If the requirement is intentionally restricted to
record/union owners, split Interface naming explicitly rather than silently
leaving it coupled to the record/union helper.

### Lua metamethod C entry points (must change)

These bypass every naming helper:

* record `__index_$RECNAME` / `__newindex_$RECNAME`
  (`16962-17124`);
* union counterparts (`17127-17216`);
* Interface `__index_interface_$CNAME` /
  `__newindex_interface_$CNAME` (`17381-17478`);
* module-global file-local `__index` / `__newindex` (`18140-18213`).

Add centralized nominal metamethod names derived from module, owner, and role,
using the same `\u2133` then `\u2131` structure.  Do not merely prepend the new
separators to the current `__index_...` text: identifiers beginning with `__`
are C implementation-reserved at file scope, and `__index_pkg_sample_Box`
also loses the structural boundaries.  Suggested role text is `index` and
`newindex` (or an explicit `titanentry_meta_*` suffix) after the owner boundary.
The module userdata pair is file-local and only one pair exists per translation
unit, but it should likewise stop using the reserved bare `__index` names; it
has no nominal-owner boundary, so a module helper should use only `\u2133`.
Because every metamethod listed here is `static`, it stays out of
`external_symbols`; the change is generated-C hygiene/injectivity, not a new
provider export or preflight entry.

## Concrete collisions removed

All of these currently collapse to one C symbol stem:

* nominal owner/member: module `a`, owner `R`, method/static `x_y` versus owner
  `R_x`, member `y` -> `a_R_x_y_*`;
* module/owner: `a` + owner `B_C` versus module `a.B` + owner `C` (same member)
  -> `a_B_C_<member>_*`;
* existing filesystem regression witness: module `record_boundary.root`, owner
  `child_Thing`, method `run` versus module `record_boundary.root.child`, owner
  `Thing`, method `run` ->
  `record_boundary_root_child_Thing_run_*`.

That last case is currently expected to fail in
`spec/coder/multi_module_libraries_spec.lua:2184-2224`; with both separators it
must become a successful compile/runtime case.  The analogous Interface
collision test at `2226-2260` should change too if Interfaces join the nominal
scheme.  Update exact old spellings in `unions_spec.lua:27-50`,
`interfaces_spec.lua:80-149`, `static_dynamic_facade_spec.lua:175-180,226-229`,
`so_import_spec.lua:562-569,637-670`, `closures_spec.lua:800-819`, and the other
`*_titanmethod` / `*_titanstatic` assertions.

Retain the independent flattened-module collision rejection
(`clash.a-b` versus `clash.a.b`, e.g.
`multi_module_libraries_spec.lua:1957-1972`) because module protocol and data
families still use the flattened module prefix.

## Data and protocol symbols

Some non-function identifiers **must** follow the callable rename: for a dynamic
import, `init_data_from_other_modules` declares file-local function-pointer data
variables under the target callable spelling (`16864-16934`), including bound
Lua/strict pointers, then assigns `loadsym`/`loadglobalsym` into them.  Those
carrier variables must use the new helper result exactly; otherwise the call
site, carrier, and lookup string diverge.

Do **not** mechanically apply callable separators to unrelated non-function
data:

* keep metadata byte arrays `<module>_titan_metadata` (`16724-16744`,
  `18240-18250`), function-tag pointer variables `<module>_functag_N`
  (`647-674`, `18291-18307`), Interface pair arrays/adapters' private IDs
  (`5593-5604`, `18061-18109`), and `_initialized` translation-unit state;
* module-userdata variables and static closures are Lua uservalue slots, not C
  symbols, so their ABI-prefix layout does not get renamed.  Likewise keep the
  serialized/revalidated `Type.Module.prefix` as `<mangled-module>_`
  (`types.lua:549-558`, `driver.lua:1196-1201`); it is a protocol/state prefix,
  not the callable stem;
* keep protocol spellings `<module>_{abi,types,init}` and
  `luaopen_<module>` (`16656-16721`, `18252-18384`), plus the source-provider
  identity function (`229-231`, `16774-16788`, `17825-17831`).  These are
  deliberately discovered by fixed ABI protocol names, not language callable
  names.  They still justify module-prefix collision preflight.
* the generated `.titan.h` include guard at `17595-17597` is a preprocessor
  macro, not a native symbol.  It may keep its ASCII spelling; after nominal
  naming stops calling `_source_private_prefix`, that helper can remain/split
  solely for the guard rather than leaking the old naming model back into
  callable symbols.

Private generated **functions** such as lambdas, Array writers, module root
initializer, callable adapters, and Interface-adjustment adapters are unique
within one translation unit and not source nominal members.  They need not gain
`\u2131`; optionally routing their module boundary through one internal helper
would improve uniformity, but is not required for collision safety and should
not be conflated with the ABI-visible nominal change.

Finally, `_linkage_symbol_name` (`305-309`) currently replaces only `\u2133`.
Extend it to replace `\u2131` with UTF-8 `ℱ` as well.  This is required for
trace-name registry keys (`18309-18325`) and any `nm`/DWARF/native-symbol
assertion; generated C declarations and `loadsym` string tokens must retain UCN
spelling so the C compiler produces the UTF-8 linkage name.
