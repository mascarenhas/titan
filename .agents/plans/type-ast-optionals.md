# Explicit optional compiler metadata

Status: implemented, independently reviewed, and locally verified

Work: [type metadata #182](https://github.com/mascarenhas/titan/issues/182),
[AST and analysis states #183](https://github.com/mascarenhas/titan/issues/183),
[language-server adoption #87](https://github.com/mascarenhas/vscode-titan/issues/87).

Both repositories use `codex/explicit-optional-metadata`. Keep all prerelease
version markers unchanged. Leave both PRs open; Linux CI is required, macOS
is waived. Check CI at intervals of at least ten minutes.

## Representation contract

- Ordinary optional Type and AST fields use nil. This applies to producers,
  Lua compiler consumers, serialized metadata, and typed Titan consumers.
- Computed fields that distinguish unchecked, checked absence, and a result
  use `{tag="unknown"}`, `{tag="none"}`, and `{tag="just",value=result}`.
  Initialize unchecked fields explicitly. Dense lists retain one tagged
  entry per slot. Unknown must remain a compiler-integrity failure when a
  completed computation is required.
- Array `isconst` uses `{tag="no"}`, `{tag="yes"}`, or `{tag="maybe"}`.
  Compare tags, never table identity or truthiness. Validate structural tags
  at constructors and persisted boundaries.
- Genuine boolean fields remain boolean, including field/module constness,
  declaration visibility, C flags, and the reserved Function.vararg slot.
  Transient relation recursion memo tables retain their cycle semantics.
- No compatibility adapters accepting old false optionals. Rebuild providers
  and use compiler-content cache identities plus structural validation.

## Audit and implementation surfaces

1. `types.lua`: callable tails and names, scopes/binders, generic aliases,
   C optional names/extents/ABI/owners, qualifiers, relations, rewriting,
   display, serialization. Keep invalid binder evidence distinct from valid
   unconstrained binders through an explicit validity result.
2. `ast.lua` and parser: optional annotations, initializer/branch/catch/raise
   expressions, optional names, lambda result inference, spread bounds, Array
   qualifiers. LPeg explicit-nil captures preserve positional arity.
3. Checker/lowering/coder: all readers and synthesized constructors; computed
   guards, Lua conversion plans, strict plans, written casts and comparisons;
   optional frozen-adapter components; generic pending annotations; dense
   plan lists. Preserve lexical traversal and omit DAG backreferences.
4. Metadata: compiled-interface validator, sourceinterface, declaration
   schemas, project/foreign/C-definition snapshots, binary compatibility.
   Checker field-macro lookup entries use Maybe3 separately from immutable
   raw header projection maps.
5. Reflection: remove `cast_metadata_optional`, use typed optional inputs,
   map tagged constness to the existing public union. Retain heterogeneous
   values only where the semantic data really is heterogeneous.
6. Language server: nil-only optional AST/type readers, typed Options,
   metadata tests, helper staging, exact compiler commit pin. Existing compiler
   and server hashes invalidate incompatible SQLite content.
7. Update implementation inventories/manuals and packaging module inventories.

## Verification and delivery

- Focused parser/type/checker/metadata tests, including direct nil assertions
  (subset comparisons cannot prove absent keys), every tagged state, dense
  arity, malformed qualifiers and missing/unknown plan rejection.
- Generated-code and runtime tests, generic constraints, C metadata, source,
  DSO/archive round trips and native reflection behavior.
- Reinstall matching compiler/providers in an isolated compiler test prefix
  and the existing vscode-titan `.titan` production prefix.
- Run Titan's complete documented local gate and vscode-titan `make verify`
  with shipping build flags, including incremental builds and package inspection.
- Independent reviews by agents that did not author the reviewed slices;
  resolve findings and commit reviewed increments with exact staged paths.
- Push the compiler commit for the server pin, open vscode-titan PR after its
  local gate, then Titan PR after both local gates. Monitor Linux CI at least
  ten minutes apart, repair failures, and keep PRs open for review.

## Progress

- Initial read-only audits completed; no unresolved maintainer design questions.
- Both worktrees were clean before branch creation.
- Compiler Type/metadata, AST/checker/coder, and language-server changes have
  separate implementation owners; the main agent coordinates inventories,
  integration, verification, reviews, commits, PRs and CI.

### Reviewed implementation

- Type/metadata, AST/checker/coder, reflection, and server bridge migrations are
  implemented and independently reviewed. Review findings were fixed with
  regression coverage: strict C extent validation, nil spread bounds, completed
  unavailable boundary plans, scalar adapter guards, failed-cast lifecycle, and
  required receiver-plan assertions.
- Ordinary Type/AST optionals use nil; Array qualifiers and computed states use
  closed tags. Positional native-layout transport placeholders stay private to
  their wire decoder and never reappear as absent fields in live compiler nodes.
- Parser/symbol/checker focused tests, type laws and serialization, C semantics,
  strict cache negatives, and code-generation integrity checks pass. Native
  stdlib providers have been rebuilt; all 21 pinned interface fixtures were
  regenerated from them, and the exhaustive compiler manifest includes all
  three new spec files.
- Local validation passed against the final installed compiler: 155 retained
  build/runtime tests, 3,704 compiler test executions across four shards, and
  all 470 native stdlib tests. The complete native phase was replayed after
  correcting its stale absent-bitfield assertion from false to nil.
- The existing vscode-titan toolchain was refreshed, and its complete shipping
  `make verify` gate passed: 407 native tests, protocol/completion/cache/Codex
  integration, 67 extension unit tests, six shard-runner tests, 12 extension-host
  tests, incremental builds, packaging, and artifact inspections.
- Delivery and Linux CI are tracked in the linked issues and pull requests;
  both PRs remain open for maintainer review.
