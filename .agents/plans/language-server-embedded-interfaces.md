# Language-server embedded compiler interfaces

## Scope and invariant

The standalone Titan language server loads the ordinary Lua compiler modules,
but its semantic resolver must not depend on a separately installed
`lib/titan/0.6/titan.a` or `titan.so`. Add an explicitly analysis-only compiler
API which accepts closed ABI/type manifests already embedded by a trusted host.
It must participate in the same source-overlap, contextual-owner, validation,
and provenance rules as a static provider without being treated as a native
link input.

Keep `TITAN_VERSION=0.6.0` and `TITAN_ABI_VERSION=2` unchanged. Increment only
`LANGUAGE_SERVER_API_VERSION`, because the new resolver input is a private
semantic-client contract. Do not relax archive scanning, make executables
loadable providers, or expose a generic current-process symbol lookup.

## Implementation

1. Validate and decode one `options.embedded_interface_provider` in
   `driver.new_resolver_context`. Its closed schema is
   `{ provider_file = <absolute path>, entries = { [module] = {
   abi = <current ABI>, types = <serialized Type.Module> } } }`.
2. Consult that provider before filesystem binary formats only after the
   caller has reached ordinary compiled lookup. Reject the whole provider for
   the context when any carried module overlaps a known/source-required module.
3. Reuse static-provider contextual owner and finalization logic, but mark the
   selected entries analysis-only and never add them to `static_deps` or native
   link inputs.
4. Return stable binary provenance using `provider_file`; semantic clients can
   stamp the host executable while the driver never opens it as a DSO/archive.
5. Bump and document `LANGUAGE_SERVER_API_VERSION`.

## Regression plan

- Validate schema, ABI, serialized-interface, absolute-path, and duplicate or
  unexpected-field failures at context creation.
- Prove embedded interfaces outrank disk providers for ordinary imports, are
  bypassed by explicit/project source and whole-provider overlap, resolve
  contextual owners from the same embedded inventory, and never enter
  `static_deps`.
- Prove `resolve_external_modules` reports the provider file and that ordinary
  compiler behavior is unchanged when the option is absent.
- Run focused driver specs, all compiler shards, syntax checks, and the normal
  Titan test gate before publishing any compiler change.

## Progress log

- 2026-08-29: confirmed the language-server executable is ET_EXEC with a merged
  metadata section and cannot be loaded or scanned as an ordinary DSO/archive.
- 2026-08-29: confirmed its initialized native closure has 13 of the canonical
  provider's 18 interfaces, so a complete metadata-only build manifest is
  required for general project analysis.
- 2026-08-29: implemented the API-4 closed embedded inventory, per-context
  decoded graph isolation, source-overlap rejection, contextual-owner
  provenance, and unconditional exclusion from native/static link inputs.
- 2026-08-29: passed the 12 focused embedded-provider specs, the complete
  151-example driver spec, all four compiler shards, the 127-check host/build
  gate, and the 205-test native standard-library aggregate.
