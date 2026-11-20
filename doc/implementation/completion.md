# Completion analysis

The compiler supplies caret-specific facts for an unsaved logical module. The
host owns buffer versions, saved dependency generations, scheduling, SQL storage
and editor coordinates. Completion uses the ordinary parser and checker with a
marked missing name; it neither introduces a language construct nor permits an
invalid expression in ordinary compilation.

## Disposable source and coordinates

`titan-compiler/completion.lua` exports `VERSION = 1` and
`TRANSFORM_VERSION = 1`. `completion.prepare(filename, text, caret)` accepts a
zero-based UTF-8 byte boundary and returns a table or `nil, reason` for invalid
input, a caret that splits a UTF-8 sequence, or an excluded token.
The table contains `text`, `request`, `kind`, `prefix`, `replacement_start` and
`replacement_end`. The replacement is a half-open span in the original text.
The host converts that span with the captured buffer's UTF-16 index.

The lexer identifies comments, strings, numbers and complete identifier tokens.
The transform replaces the complete name around the caret, preserving `.` or
`:`, receiver chains and existing arguments. Empty names get the same legal
identifier. The checker identifies it using the filename and transformed source
location carried in `request`; an unrelated identifier with the same spelling
cannot activate the hook. A multiword C primitive is one replacement leaf:
`foreign const *unsigned lo|ng long` replaces `unsigned long long` and retains
`foreign const *`. The leaf follows `foreign`, `owned` or `foreign type Name =`.
Inside a `foreign function`, whose signature and body write C types without
that prefix, it also follows the `:` of an annotation and the `as` of a cast:
`local x = p as const *unsigned lo|ng long` replaces the same leaf, and the
context is `foreign`. `prepare` finds the enclosing foreign function from the
tokens before the caret: a `foreign function Name` opens one, and the block
keywords (`if`, `do`, `repeat`, `until`, `end`) close it. A reserved word
written as a name does not count. It is a name before `=`, where it names an
argument (`end = 5`), and after a token that a name or a type follows: `.`,
`:`, `,`, `(`, `{`, `*`, `as`, `const`, `foreign` or `function`. That covers a
member, a function or a C type called `end` or `repeat`, and `foreign` as a
member or before a C type in ordinary code. Import-string completion
returns `kind = "import"`, the literal's contents as its replacement span, and
unchanged source; the host uses its captured eligible module catalog.

`original_byte(request, analysis_byte)` reverses offsets after the one edit;
positions inside the synthetic identifier map to the original leaf start.
Comments and unrelated strings are excluded. Arbitrary malformed surrounding
syntax is not repaired. A parse failure gives no typed candidates.

`dependencies(files)` parses the complete ordered contributor set, where each
item is `{filename, contents}`. It returns sorted unique
`{module_name, source_required}` records, or `nil, error`. Import shorthand and
the terminal `.titan` capability marker come from the parser. The host must hold
its compiler permit because parsing has process-local state.

## Context and candidates

Pass `request` as `completion` in the analysis resolver options. After loading
its source override, `driver.imported[module_name].completion` contains
`{version, quality, kind, candidates, scopes}` even when the expected missing
name produces a checker diagnostic. Quality is `complete`, `partial`, or
`unresolved`; contexts are `lexical`, `type`, `dot`, `colon`, or `foreign`.
Other errors can make an otherwise useful context partial.

Each candidate is a scalar record with `name`, LSP integer `kind`, `detail`,
`lookup_domain`, `lookup_key`, `type_key`, `scope_id`, `scope_depth`,
`declaration_order`, `available`, `islocal`, `visibility`, `owner_key` and
`access_mode`. The scope array contains the active ancestry at the hole, with
`id`, `parent_id`, `kind`, `filename`, original `byte_start`/`byte_finish` and `caret_byte`. These identifiers are local
to the analysis. `type_key` is an opaque fact identity, not a runtime type ID.
Candidates contain no AST or mutable compiler type tables. An optional
`documentation` field holds a detached `{summary, description, tags}` document;
all its leaves are strings. The host validates and renders this subrecord once
when materializing scalar SQL facts. See [documentation metadata](documentation-comments.md). The host applies
case-sensitive prefix ranking and limits after compiler visibility and binding
selection, and qualifies every saved identity with its committed generation.

The observation points (`completion_lexical`, `completion_qualified_type`,
`completion_members`, `completion_foreign`, and `completion_finish` in
`titan-compiler/checker/completion.lua`) precede failed lookup of the dummy and the current-module
`M.member` rewrite. Standalone references are checked far enough to capture their
receiver in completion mode; their ordinary statement error remains. Lexical
facts observe the symbol table at its actual initializer, loop, repeat, catch,
closure and generic lifetime. Member facts use the resolved and specialized
receiver, direct source-import visibility, interface view, and dot/colon split.
C field candidates reuse the real aggregate/typedef/pointer/owned and final
macro-projection lookup. Foreign names use the distinct C type environment,
independent of a lexical `ffi` shadow.

## Detached saved descriptors and private preparation

`completion.describe(entry)` returns `{version, module_name, candidates, documentation?}` for
saved indexing. Module facts use `owner_key = "module:" .. module_name`;
nominal member facts use `"nominal:" .. fqtn`; C facts use a separate foreign
lookup domain. Access modes distinguish `dot`, `static`, `colon` and `type`.
Public and private declarations remain separate rows.

The project manifest (`projectcache.VERSION`) retains these scalar
`completion_facts` alongside the closed declared owner graph and ordered `.ffi.h` plans. Decoding an
entry and describing it does not install a registry or retain a source AST.
External source modules require the same actual compact entry to preserve
private/generic capability and generated-header plans. The equality-only
`source_manifest` string cannot reconstruct those declarations.

The host captures dependency descriptors, source bytes, header cache inventory,
and semantic generation coherently during normal saved publication. Decode only
the selected dependency closure in a private compiler instance. Install its own
`driver.imported` and `types.registry` under the shared compiler permit, restoring
the caller's state afterward. Never restore or await the saved workspace graph.
The first activation in a process adopts a host-installed pair; only a later
target-identity change replaces it. Install or restore a pair only for the
selected current owner, never across a target change
([Semantic-cache ownership](browser-target.md#semantic-cache-ownership)).

Use these resolver options together:

- `analysis_only = true` and `completion_closed_world = true`;
- `source_overrides` for the complete active logical module;
- `cached_source_entries` containing private decoded declared entries;
- `cached_binary_interfaces`, mapping names to `{serialized, kind, filename}`;
- `transient_caches = true` and a private I/O/cache adapter.

Analysis-only checking keeps source-level generic types and case bindings
without runtime erasure, while still freezing the declared interface/registry
and running `completion_finish`
([Source semantic bindings](checker.md#source-semantic-bindings)).

The binary kind is `embedded`, `dynamic`, or `static`. The closed catalog rejects
missing dependencies and source-required imports of captured binaries. It never
falls back to newer filesystem source or providers, and never consults disk to
re-acquire a captured binary's `source_requirements` frontier (any nominal owner
exposed by a captured binary must come from the captured checked source entries,
captured binary interfaces, and registry). Saved indexing obtains the
eligible embedded and already selected binary inventory through
`driver.completion_binary_catalog(context)` after source/provider precedence is
settled. Capture every module carried by each finalized selected static
archive, including siblings that saved code never imported. After finalization
(`context.finalized_selection`), the catalog also captures finalized contextual
binary owner views (`resolution.interface` from `context.contextual_resolutions`)
for owners not already present in the catalog or `driver.imported`—under
`analysis_only`, both carried and independently looked-up contextual binary
owners (only the interface actually used, never the whole inventory of an
archive inspected only for that owner), and outside `analysis_only` carried
(`not resolution.ordinary_lookup`) owners only—omitting any owner with
competing finalized contextual provider views. Eligible embedded
interfaces retain precedence over unimported static siblings; actual imported
selections and source exclusions remain authoritative. Archives inspected only
for contextual type recovery or displaced by source are not selected inventory.
That helper does not discover filesystem modules, manufacture ordinary imports
for contextual binary owners, or import archive siblings.

`transient_caches` disables persistent native C-probe records per resolver; it
never changes process environment. The host's private graph-cache adapter may
read captured compatible payloads, but writes and metadata refreshes remain
transient. The ordinary resolver owns generated C scratch cleanup. Neither
completion facts nor analysis results may be promoted into saved compiler state
or persisted on save.

Materialize scalar rows before serving SQL completion queries. A SELECT operation
must not call this module, decode descriptor payloads, traverse ASTs or acquire
the compiler permit. The host retains its one-connection transaction/read gate
and validates the captured generation, document session and constituent versions
inside that gate before publication and before a complete read.

C enum candidate eligibility is conservative. The extracted header cache retains
original enum expressions and implicit ordinals. The existing target-profile
integer evaluator proves ordinary target-int enumerators without native probes;
wide or unevaluable entries are omitted and make the result partial unless normal
checking has already validated the exact type. Host-Lua enum numeric values are
never range evidence. The header cache (`cdriver.HEADER_CACHE_VERSION`) carries
the enum expressions and ordinals.
