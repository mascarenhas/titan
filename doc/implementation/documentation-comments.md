# Documentation metadata

`titan-compiler.documentation` extracts LDoc-style comments after a successful
ordinary parse. It uses the existing lexer to distinguish comment tokens from
quoted and long strings. A source-position map attaches blocks to top-level
AST declarations and nominal members without changing grammar alternatives,
source locations or semantic checking. A prefix `@module` block becomes
`ast._documentation`; the driver carries the main source's block into a folder
module's merged AST.

## Detached contract

Each document is a plain table with exactly these fields:

```lua
{
    summary = "One sentence.",
    description = "Remaining Markdown prose.",
    tags = {
        {name = "param", value = "input Description."},
        {name = "usage", value = "standard-library-string.md#anchor"},
    },
}
```

`tags` is a dense ordered list. Repeated and unknown names are legal. The text
is data, not Lua, HTML or an executable LDoc configuration. `documentation.copy`
validates and detaches this closed contract; it rejects metatables, sparse tag
lists, unknown fields and nonstring values. `copy_map` validates maps from
selected declaration names to documents.

Parser declarations retain `_documentation`, including the nested `Ast.Decl`
for top-level variables. The signature visitor calls `bind_declaration` before
body analysis, placing documents on declaration identities (`Type.Field`,
`Type.Method`, `Type.StaticMethod`, nominal owners and variants). `@field` tags
supply inherited field descriptions only when direct comments are absent.
Documented owners/variants also supply documentation for their compiler-synthesized
constructors, including parameter/return tags and relative usage links. Undocumented
owners retain their previous metadata. Module assembly copies documents to `Type.ModuleMember`/`Type.ModuleVariable`
and places module documentation on `Type.Module._documentation`.

Concrete transparent aliases require a separate named document map,
`Type.Module._type_documentation`. Decorating their resolved target would attach
one alias's documentation to unrelated declarations sharing that target.
Qualified type-member checker identities retain their selected name's document.
Public metadata filters the named map to exported type members; compact source
manifests also retain private alias documentation for direct source imports.

`documentation.for_node(node)` returns the document for an AST occurrence or
its actual declaration. It follows `_decl`, `_method` and `_field`, resolves
import bindings through their `Type.Module`, and uses the selected named map
for qualified alias/type members. It does not infer documentation from an
expression's result type. Generic rewriting copies documents without attaching
AST edges to rewritten descriptor graphs.

## Persistence and language-server integration

`types.serialize` wraps documented declaration constructors in
`Documented(existing_constructor, document, optional_named_map)`. Undocumented
constructors retain their previous spelling and arity. `types.Documented`
validates and copies documents during source-free metadata decoding. Thus the
ordinary dynamic `_types` protocol, static-provider metadata, object metadata,
embedded interfaces and captured completion binary catalog all carry the same
information. Source-interface fingerprints include documentation on private
members and private aliases, so `.titan` importers invalidate their saved editor
facts after documentation edits. Native layouts, type identity and runtime ABI
remain unchanged.
`types.serialize_semantic` excludes documentation for source/compiled semantic
comparisons, binary-compatibility requirements and every runtime metatable/callable
tag. The runtime reflection hydration grammar remains unchanged; editor documents
are exported only in module-interface metadata.

The closed declaration schemas retain documents in compact/encoded project
entries and their scalar completion facts. `completion.describe(entry)` exports
module `documentation` and candidate `documentation`; completion observation
exports candidate documentation after resolving the real specialized declaration.
The document subrecord is detached and contains only text/list data. Hosts
validate it at their narrow compiler boundary, render Markdown once, then store
scalar text for SQL selection. `driver.completion_binary_catalog` also exports
module documentation for already selected provider siblings, preserving ordinary
source/embedded/static selection precedence.

All version markers remain unchanged during this prerelease change. Compiler
content identity invalidates language-server caches so old entries are rebuilt;
legacy metadata without documents remains valid. Documentation additions do not
change generated native behavior. Focused regressions live in
`spec/documentation_spec.lua` and the native reflection regression in
`spec/coder/documentation_spec.lua`, with the existing completion and project-cache
suites checking their broader contracts.
