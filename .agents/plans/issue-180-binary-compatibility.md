# Titan issue 180 research

Issue: https://github.com/mascarenhas/titan/issues/180
Title: Do not require exact metadata when loading binary dependencies
Read with gh on 2026-09-25; open, no comments.
CLI: /tmp/gh_2.101.0_linux_amd64/bin/gh
Full issue JSON: /tmp/titan-issue-180.json
Repository: /var/home/mascarenhas/Code/titan
Research base: master, 641aade0 (merged native userdata payload PR 179).
Checkout was clean; research made no repository changes.

## Requested process

Create a new local branch, implement with frequent commits, complete local tests
and independent code/documentation reviews, then push and open a PR. Monitor
Linux CI at ten-minute polling intervals. macOS CI is waived. Use gh for every
GitHub interaction. Keep the PR unmerged unless later requested otherwise.
Keep compiler version and ABI unchanged; keep LANGUAGE_SERVER_API_VERSION at 1.
Keep existing module metadata unchanged and add a separate compatibility
protocol. Update human language and implementation manuals, plus relevant agent
skills with audience-appropriate independent review.

## Requested compatibility contract

Only separate shared-object dependencies receive the new runtime check. Preserve
the ABI check first. Same-binary/source/static dependencies remain frozen/direct.
Check only used top-level functions/variables and referenced nominal types.
Functions/methods/statics require exact erased signatures and parameter names;
only used concrete nominal methods/statics are checked. Variables require exact
erased types but declaration order is immaterial. Referenced records require
exact ordered public fields; private fields may change. Referenced unions require
exact ordered public variants and public-first tags; private variants may change.
Referenced Interfaces require all ordered fields/methods. Aliases to nominals
appear in their corresponding nominal category. Preserve nominal owner identity.
An embedded Lua metadata chunk and generated importer-specific Lua verifier are
the issue's suggested design, using the initializer's Lua state and errors.

## Maintainer decisions

1. CONFIRMED: Treat binary imported record literal construction as an implicit
   reference to the synthesized public Record.new. Adding the first private
   field removes public new and rejects consumers constructing the record, while
   receive/access-only consumers keep working. Otherwise old literals allocate
   too-small objects according to the former complete public-only layout.
2. MAINTAINER CLARIFICATION: "Titan union case does not make any exhaustiveness
   promise." Preserve no-match/no-op behavior; do not add an unknown-variant
   exception. After the separate existing return-proof optimization was
   explained, the maintainer said: "In that case yes, I think it is fair for the
   load to fail." FINAL DECISION: preserve existing checker control-flow proofs
   and record when a consumer relies on the closed variant inventory. Reject
   replacement at LOAD TIME if adding private variants invalidates that proof.
   Do not tighten source coverage rules or disable existing return inference.
   Consumers with no such proof dependency continue accepting private changes.
   An explicit independently terminating else does not require a closed-world
   proof; a falling-through else ignored because of complete coverage does.
   Same-binary/source-frozen dependencies bypass runtime compatibility checks.

The record decision and union clarification settle the research questions.
The persistent implementation goal is now active, created from this note and
the issue. Its final union decision supersedes the earlier trap/conservative-
checker alternatives in research-agent messages.

## Verified implementation seams

- coder/module.lua:138 import_module emits loadlib, titan_check_abi, then an
  exact serialized types check. generate.lua:696 preserves declared metadata
  separately from erased code types; 726 emits _types, _layouts, and _abi.
- runtime titan.c:1183 titan_check_abi and :1220 titan_check_types own native
  checks. Preserve stack discipline, ABI-first failure, missing/invalid protocol
  diagnostics, and checks on already-initialized/global symbol paths.
- coder/module.lua:238 init_data_from_other_modules uses a checked explicit
  handle or RTLD_DEFAULT for transitive nominal owners after provider init.
  Reuse driver final static_deps/native provenance to skip same-binary checks.
- Contrary to the issue's premise, current imported variables AND first-class
  module/static function closures use constant UV indexes. See
  coder/expressions.lua:200-257, coder/statements.lua:862-881, and
  types.public_module_prefix_layout at types.lua:958. Add producer-owned runtime
  slot resolution for separately loaded dependencies while preserving canonical
  closure identities; keep direct/source accesses on their fixed layout.
  Clarification after maintainer follow-up: ordinary mod.func() calls already
  bypass the closure slot. coder/calls.lua:2272 selects the exported native
  symbol, supplies the imported module state and NULL _fn, and module.lua:245
  resolves the native symbol once via loadsym for a DSO. Keep this direct call
  path. Only mod.func used as a value fetches the canonical closure slot. In
  the nested expression _mod->uv[IMPORT_SLOT] -> imported->uv[MEMBER_SLOT], the
  outer self-owned IMPORT_SLOT properly stays constant; the current inner
  imported MEMBER_SLOT is also emitted as a literal and needs runtime resolution.
- nominallayout.lua already places public traced fields before private traced
  fields and public native members in a real first prefix subobject. Actual
  nuvalue controls getudatamem, so private field counts do not shift public native
  offsets. Source-absolute logical field indexes are not compatibility identity.
- checker/declarations.lua:1123 assigns union tags in source order today. Change
  assignment to public first, private after, without reordering source evaluation.
- coderecord in coder/expressions.lua:756 allocates complete records locally;
  coder/nominalcalls.lua also inlines direct synthesized constructors.
- checker/statements.lua:1399 treats covered_variants == union.nvariants as
  exhaustive. coder/statements.lua:2839 has a fallthrough default; flow.lua:566
  emits zero-carrier unreachable returns. New private variants can reach these
  paths and return NULL as a required string/nominal, or encounter pruned code.

## Usage and erasure design

Use a per-consumer checked-AST manifest, not shared descriptor _used flags.
Capture successful member selection, writes, direct calls, first-class and bound
method references, inferred nominal values, contextual constructors, and implicit
Interface witnesses/conversion plans. Do not recursively traverse every _decl or
imported module graph: that marks unused provider surfaces.

Selection seams: checker/variables.lua VarDot; checker/expressions.lua ExpCall
and ExpMethodRef; checker/type_syntax.lua TypeQualName; common.lua
generic_bare_forwarding_alias_target; expression_lists.lua
generic_resolve_named_record_constructor_context and
generic_finish_named_record_constructor; statements.lua StatCase.

Implicit dependencies: checker/interfaces.lua freeze_interface_implementation
and make_interface_conversion; open conversions in expression_lists.lua;
conversion plans introduced by checker/lowering.lua. Concrete methods used only
by Interface adapters must be checked.

Use types.erase (types.lua:2672) on canonical declarations, never the specialized
signature of an individual generic call. Parameter names live on ModuleMember,
Method, or StaticMethod descriptors. Preserve const qualifiers and vararg/flexible
result shape. Keep semantic metadata distinct from compatibility metadata.
checker/entry.lua and lowering.lua generic_lower_erased_core preserve declared
and erased graphs. Resolve aliases/exposing module names separately from canonical
nominal owners using checker/imports.lua's existing nominal-owner recovery and
provider provenance. register_module_interface's eager validation of the entire
public graph is not a usage signal.

## Validation and documentation direction

Regression tests should compile consumer v1, replace ONLY the provider, and run
the unchanged consumer in a fresh process. Include compatible unused additions/
removals/reordering, used mismatches, names, generic erasure, mutability, variables
and closure slot movement, public/private nominal layout, aliases/transitive
owners, implicit Interface methods, and same-binary bypass. Keep ABI mismatch
first and test malformed/missing separate compatibility metadata.
Use owning pure/checker/coder test layers, existing DSO/archive/prefix-provider
scaffolding, and register new compiler specs in the CI grouping manifest.
Run focused tests, complete mixed suite, and independent review before pushing.
Available previous prepared prefix /tmp/titan-174-validation is a candidate only;
verify and rebuild matching compiler/runtime/provider before relying on it.

Docs needing review: language/modules.md, language/static-compiled-modules.md,
language/unions.md, language/nominal-storage.md; implementation/lua-interop-internals.md,
implementation/nominal-storage.md, implementation/unions.md, provider docs and
indexes. titan-programmer covers module packaging and needs updated operational
guidance; add/update relevant tester/FFI guidance only where contracts change.

## Canonical provider clarification during implementation

The maintainer confirmed that dynamic runtime imports must consult the logical
module registry first. An already initialized provider wins even when a
consumer was built against a different physical file. This includes providers
embedded in the executable. Check compatibility against that canonical provider
and use its native functions and slots; do not reject it merely for differing
from the recorded file, and do not load the alternate file first.

Research exposed the gap: the registry already canonicalized module userdata,
but generated imports first dlopened the recorded filename and cached its
symbols. Mixed provider versions could therefore use v2 slot numbers/native
code with v1 userdata. The reproduced read returned an unrelated value 99
instead of the canonical count 42.

Implementation now publishes a compiler-generated native export resolver in
each module userdata's native payload, reachable from every initialization path.
Dynamic imports select/check/initialize serially so an earlier dependency can
elect an embedded provider for a later import. Bindings are recovered from the
resulting canonical provider. Transitive owners use logical registry lookup.
Imported native addresses, slot indexes, Interface method tables, and function
tag caches live with each Lua state's importing module, avoiding cross-state
rebinding through file-static C globals. Generated ELF exports bind locally
through protected visibility; ordinary Darwin two-level linkage already has
that property. Direct/source/static edges retain their frozen bindings and use
the existing physical-provider identity guard.

Regression coverage includes absent alternate files, canonical incompatibility,
an earlier facade electing an embedded provider, executable-embedded providers,
and two simultaneous Lua states choosing different compatible providers while
sharing one consumer DSO. Independent code and documentation review and full
local validation are being repeated for this extension before publication.
