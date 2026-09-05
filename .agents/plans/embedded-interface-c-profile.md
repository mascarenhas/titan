# Embedded interface C target profiles

## Scope

Repair the SDK-free language-server compatibility blocker discovered by
vscode-titan PR #46 Linux CI on pristine master `0ac5df1`. The public reflection
interface contains portable C `int` callback results. Registration correctly
requires numeric lowering traits, but API 4 can obtain its profile only through
native C probes and `lua.h`; that violates the metadata-only package contract.
All compiler work stays in this temporary checkout on
`fix/embedded-interface-c-profile`. The active sibling checkout is untouched.

## Design

- Advance only the private language-server API to 5; preserve release 0.6.0
  and generated-code ABI 2.
- Extend the trusted analysis-only embedded provider with closed, declarative
  target-profile data produced from the exact build SDK/toolchain. Validate and
  copy this data, reconstruct canonical numeric leaves and lowering traits,
  and reject malformed identities or incompatible embedded numeric metadata
  before publication.
- Separate pure target-profile acquisition from native C probe acquisition.
  Embedded semantic analysis may use the validated build profile without an
  SDK. Actual C header/probe work still requires the native toolchain and must
  agree with the declared target. Ordinary compiler contexts retain their
  current live-profile behavior.
- Preserve embedded-provider source-overlap rejection, contextual lookup,
  per-context graph isolation, and exclusion from all native link inputs.
- Do not skip normalization, fabricate traits in the language server, bundle
  SDK headers, or inject process-global compiler state from the bridge.

## Verification and delivery

1. Regress profile serialization/validation, numeric trait reconstruction,
   malformed/mismatched metadata, SDK-free semantic use, and retained native
   probe errors and ordinary compiler behavior in existing Lua spec shards.
2. Run focused specs and complete compiler/native validation with the prepared
   isolated prefix, keeping shared generated stages under one owner.
3. Update compiler API documentation and the language-server generator, API
   checks, tests, and package smoke. The smoke must clear ambient C include
   paths and select an unavailable C compiler.
4. Complete vscode-titan local verification and real stdlib indexing before
   publishing the separate compiler PR. Pin its tested commit in vscode-titan.
5. Leave both PRs open and monitor only Linux CI. Do not dispatch macOS CI.

## Initial evidence

- vscode-titan run `33990472201` passes 221 native, 56 JavaScript, and 12
  extension-host tests, then fails the self-contained VSIX reflection smoke:
  `the C probe service has no authoritative target profile`.
- Removing inherited `C_INCLUDE_PATH`, `CPATH`, and `CPLUS_INCLUDE_PATH`
  reproduces that exact failure locally with a fresh extracted VSIX and cache.
  The original local pass used headers from an unrelated installed Titan SDK.

## Completed local verification

- 208 focused tests pass across `csemantics_spec.lua`, `driver_spec.lua`, and
  `checker/c_ffi_target_profile_spec.lua`.
- Full `CCACHE_DISABLE=1 TITAN_JOBS=4 TITAN_ROCK_TEST_JOBS=4 make -j4 test`
  with a fresh `/tmp/vscode-titan-compiler-y5yweR/compiler-test-prefix` passes:
  128 retained Busted checks, four compiler shards totaling 3,286 tests, and
  all 241 native stdlib tests. The private SDK is configured at its actual
  prefix; it does not modify the extension's production `.titan` installation.
- The extension's complete uninterrupted `make verify` passes: 222 native,
  56 JavaScript, and 12 extension-host tests plus protocol/Codex smoke, VSIX
  packaging and inspection, plugin validation, and staged installation.
  The extracted VSIX reflection/callback smoke runs with ambient C include
  paths removed and an unavailable C compiler selected.
- The configured Titan workspace indexes all 114 saved files across 59 modules
  with zero diagnostics. Reflection/async hover and timer/uv/reflection
  definition queries pass; unchanged queries do not trigger reindexing.
- Two independent reviews of the production boundary and a final
  `git diff --check` found no issues. Compiler and extension PRs remain open
  for maintainer review; monitor push-triggered Linux CI only.
