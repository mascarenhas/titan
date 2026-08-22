# Source-visible interface identities for incremental language-server invalidation

Status: implemented on `codex/parser-linearization` and Titan PR
[#101](https://github.com/mascarenhas/titan/pull/101), stacked on the unreleased
language-server compiler API in PR #98. The consumer work is tracked by
[`vscode-titan#12`](https://github.com/mascarenhas/vscode-titan/issues/12).

This follows the parser linearization work in the same PR. The parser fixes
remove the dominant cost of every check; this work prevents a saved edit from
checking source dependants at all when the declarations visible through an
explicit `.titan` import did not change.

## Problem

The language server currently gives each checked project module two graph
identities:

- the compiler's serialized public `Type.Module`, used by ordinary imports;
- a concatenation of the module's raw saved source bytes, used by explicit
  `.titan` imports.

The graph's fixed-point invalidation is already correct, but the second token
is too broad. A comment, blank line, implementation-body edit, or initializer
edit changes the raw bytes and therefore needlessly reparses every direct
source dependant. On `vscode-titan`, a comment-only edit in
`server.application` consequently checked both the provider and the much
larger `application_test` source dependant.

The compiler is the only component that owns the complete distinction between
implementation state and the source-visible declaration interface. The server
must not duplicate that distinction by walking untyped compiler tables.

## Semantic and compatibility invariants

- Keep `types.serialize(Type.Module)` unchanged. It remains the reconstructible
  public binary interface, excludes source-only state, and rejects C FFI
  descriptors.
- Add a second compiler-owned serialization that is opaque, deterministic, and
  equality-only. It is not executable Lua and is never decoded as metadata.
- Keep `driver.LANGUAGE_SERVER_API_VERSION` at 3: this API remains unreleased.
- A successful checked source entry always has a nonempty source-visible
  serialization. A failed check publishes no manifest. Binary entries have no
  source-visible serialization.
- The source serialization changes for every declaration property a direct
  `.titan` importer can observe, including named-argument parameter names,
  generics, locality, constness, nominal members, variants, methods/statics,
  source foreign functions, and source-visible C types.
- It excludes comments, whitespace, diagnostic/source spans, function and
  method bodies, variable initializers, module initializers, transient generated
  paths, checker caches, lowering annotations, and other implementation state.
- Declaration identities used by the semantic index must remain stable across
  comment/whitespace edits even when line numbers move. Module-level private
  declarations use logical module/owner/name/role identities; scoped locals may
  remain location-based because they cannot cross a module boundary.
- Ordered source declarations and nominal field/variant slots retain their
  order. Keyed maps are sorted with Titan's bytewise ordering, independent of
  Lua hash iteration and locale.
- Source-only C graphs are encoded canonically, including all declarator axes
  relevant to checking/code generation. Cycles and sharing never leak Lua table
  addresses into the result.
- Exact ordered C-header dependency identities remain conservative input to the
  source surface. Temporary checking/generated-header paths do not.
- Raw saved-file contents/stamps remain the authority for deciding whether the
  provider itself must be checked. The semantic identity controls only whether
  its importers become dirty.

## Compiler implementation

### 1. Canonical opaque encoder

Add `titan-compiler/sourceinterface.lua` with a versioned, length-framed byte
encoding. It accepts one complete checked source entry and emits:

1. the ordinary public `types.serialize(entry.type)` string;
2. the dense public and source-only module member sequences;
3. public and source-only type-member maps in bytewise key order;
4. complete source views of public and local records, unions, and interfaces,
   including locality flags, dense fields/variants, sorted functions/methods,
   generic binders/scopes/constraints, callable tails, and parameter names;
5. canonical Titan and source-only C descriptor graphs;
6. the ordered compiler-reported C-header dependency triples.

Use explicit descriptor schemas instead of a generic table dump. Reject
unknown/malformed source-visible descriptors rather than silently omitting a
new semantic field. Use deterministic traversal/back-references for cyclic C
aggregate graphs. Never encode arbitrary tables, AST nodes, absolute temporary
paths, or `tostring(table)` identities.

### 2. Driver publication

Expose `driver.serialize_source_interface(entry)` as the compiler API boundary.
Validate that the candidate is a complete checked source module with a source
`Type.Module`, dense source constituents, and normalized header dependencies.

After a clean source check, compute and store the result as
`entry.source_manifest`. Treat encoder rejection as a compiler analysis error;
do not allow a nominally successful source entry without the token. Require the
same field on caller-certified cached source entries so retained annotated ASTs
cannot silently lose their identity.

Do not change normal `titanc` output, static/dynamic metadata, ABI serialization,
or the compiler's synchronous I/O strategy.

## Language-server consumption

### 1. Typed bridge boundary

Extend the Titan `Manifest` bridge record with optional
`source_serialized`. Fresh project/external source snapshots require the raw
driver entry's nonempty `source_manifest`; binary snapshots use `nil`; failed
checks keep `manifest == nil`. Extend metadata-only cached external-source
records with the same opaque string. Only the public `serialized` value is
passed back to the compiler decoder.

Do not inspect or reconstruct the source string in Titan. Missing, empty, or
wrong-typed compiler metadata is a `BridgeError`; never fall back to raw source
bytes.

### 2. Graph identity and cache trust

Replace the project service's raw-source propagation digest with the compiler
source serialization. Keep the existing graph comparison:

- ordinary edge: compare public serialization;
- explicit `.titan` edge: compare public and source serialization;
- unchanged importer result: stop that fixed-point branch.

External source-cache trust is a separate question. Add an
`analyzed_input_identity` to `ExternalModule`, derived from the exact source
stamps and header identities which produced its cached metadata. Revalidation
updates observed stamps while retaining the old analyzed identity, so changed
external bytes cannot reuse stale metadata merely because the stored semantic
identity happens to match. A fresh compiler publication replaces both.

### 3. Stable cross-module symbols

Update compiler-bridge declaration identity for local module-level variables,
functions, records/unions/interfaces, aliases, methods, statics, fields, and
variants to use stable module/owner/name/role keys. Preserve location identities
for block-scoped locals. Verify that references retained in a clean direct
source dependant still resolve to a provider declaration after a leading
comment shifts every provider location.

## Deterministic regressions

### Compiler

- Reject malformed/non-source/incomplete driver entries and malformed header
  dependency arrays; preserve API version 3.
- Prove repeat and fresh-resolver output is byte-identical and independent of
  keyed insertion order/locale.
- Prove comments, blank lines, function/method bodies, initializers, and module
  initializer changes retain the same source serialization, including leading
  comments which shift declaration locations.
- Table-drive inequality for top-level member name/order/type/constness;
  callable parameter names/types/results/variadic and flexible tails; generic
  binders/constraints/aliases; record/interface fields and methods; union
  variants; local/public locality; and source foreign signatures.
- Prove public-nominal local member changes and local aliases change only the
  source identity while ordinary public serialization stays equal.
- Cover C pointers/qualifiers, arrays/bounds, function ABI/style/variadicity,
  typedefs, enums, aggregates/cycles, owned shapes, FFI scope, and ordered
  header dependency kind/path/identity. Header-content identity changes remain
  conservative even if the physical header edit was only a comment.
- Retain existing tests proving ordinary public metadata excludes compiler-only
  source state and C FFI.

### vscode-titan

- Bridge project/external/binary/failed snapshot normalization, including
  rejection of missing/wrong/empty source metadata and round-trip reuse from
  cached source interfaces.
- Comment/body-only provider edit: check and commit only the provider; ordinary
  and `.titan` dependants remain clean.
- Source-private signature/member edit: check the provider and direct `.titan`
  dependant; ordinary dependant stays clean; unchanged dependant metadata
  stops the wave.
- Public edit: check both ordinary and source dependants, then retain normal
  fixed-point stopping.
- Folder-module comment-only constituent add/remove or edit does not propagate;
  adding/removing a private declaration does.
- Failure/recovery retains the last committed index and invalidates importers
  only after a successful changed manifest.
- Changed external stamps never qualify for cached-interface reuse, even when
  the previous source-visible string is unchanged.
- A cached direct source dependant's definition/reference identities still
  join a rechecked provider after leading comments move source locations.

## Verification and delivery

1. Run focused compiler source-interface/driver/type/checker specs and their
   CI LuaCov shard, then the full Titan `make test` gate.
2. Commit the compiler API and tests on `codex/parser-linearization`, push to
   the existing PR #101, and require Ubicloud Linux, sanitizer, compiler/
   language LuaCov, and Codecov patch coverage to pass; macOS remains skipped.
3. Install that exact Titan commit into vscode-titan's isolated `.titan`
   toolchain, implement the typed bridge/service changes and focused server
   tests, then run the full documented vscode-titan gate.
4. Re-run the real 47-file `vscode-titan` cold index and saved
   `application.titan` refresh. Record per-generation checked/committed module
   counts, compiler/index CPU, wall time, protocol latency, and watcher passes.
5. Commit and push exact vscode-titan paths without staging the user's
   `titan-config.lua`. Update issue #12 and PR #101 with the implementation and
   measured evidence. GitHub Project placement remains deferred until the
   available token can access Project V2.
