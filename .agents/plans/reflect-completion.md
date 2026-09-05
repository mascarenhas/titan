# Complete runtime reflection

## Scope and delivery

Complete the existing `feat/reflect` work and PR #130. The earlier compiler and
parser repairs are committed as `6ca5f1b2`. Leave both stashes intact. Implement,
test, review, and document reflection, then commit, push, update the PR description,
and monitor the push-triggered Linux checks. Do not dispatch macOS CI or merge.

## Implementation

1. Generate one private accessor per public record/interface field. Member maps
   store raw lightuserdata pointers; method entries remain closures. A record
   accessor boxes reads and applies the existing checked dynamic write conversion
   and GC barrier. Interface accessors box reads only. Keep the declaring module
   argument because conversion plans use module-owned type identities.
2. Cache accessor pointers and their declaring module in private const `FieldType`
   fields during hydration, reading the owner from `TITAN_MT_MOD`. Reflected access calls these directly with rooted
   receivers and values, preserving bounds checks and public-field ordering.
3. Hydrate generic occurrences according to runtime erasure: unconstrained
   parameters become `is_value`; constrained parameters become `is_named` for the
   outer interface. Erase generic arguments and leave resolution to explicit
   `:resolve()` calls. Make nested hydration save/restore its context.
4. Repair verified reflection defects exposed by the expanded suite, including
   nominal-registry initialization, interface method-list ordering, numeric subtype
   inspection, and the `is_mutable` constness spelling. Audit foreign descriptors
   and union payload boxing rather than assuming raw storage is a public value.
5. Keep compiler version 0.6.0 and ABI 2 unchanged, as explicitly requested for
   this prerelease work.

## Validation and documentation

- Compiler cases cover pointer member maps, dynamic record/interface behavior,
  private-field gaps, conversions, and generated accessor ownership.
- Native reflection cases cover the public inspection variants, descriptor
  discovery/resolution and generic erasure, direct getter/setter conversions,
  constness and bounds, canonical Array values, and meaningful GC retention.
- Run focused checks during development, then the full compiler and native suites
  with an isolated current installation and the retained packaging gates.
- Update both existing reflection manual chapters and their index summaries, and
  revise the project-local `titan-reflect` skill. Validate examples against the
  final implementation and review the completed diff independently.
- Refresh the exact stdlib metadata snapshot from the final built provider.
- Commit and push only after local gates and review; update PR #130 around final
  behavior and validation, then resolve any Linux CI failures within this scope.
