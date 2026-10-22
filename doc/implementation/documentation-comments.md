# Documentation metadata

`titan-compiler/documentation.lua` extracts LDoc-style comments after a
successful ordinary parse, binds them to declaration identities during
checking, and serializes them into module interfaces. Comments never change
grammar alternatives, source locations, semantic checking, native layouts,
type identity, or the runtime ABI.

## Attachment rules

`parser.parse` calls `documentation.attach(tree, source)` on success. It scans
the source with the ordinary lexer's comment and string patterns, so a
doc-looking string literal never attaches. Block boundaries:

* A line comment starting with three or more dashes (`---`) starts a block,
  closing any open one.
* Directly following `--` line comments continue the open block, including
  `--`-only lines, which keep paragraph breaks.
* A blank line or any non-comment token closes the block.
* A long comment whose body starts with `--` (`--[[-- ... ]]`) is a
  self-contained block.

A closed block attaches to the AST node that starts at the next
non-whitespace position after it. Only top-level nodes (excluding synthesized
record/union constructors) and their `members`, `fields`, or `variants` are
candidates; a `TopLevelVar` also copies the document to its `decl`. A block
before the first significant token that contains `@module` becomes
`ast._documentation`. For a [folder module](folder-modules.md),
`driver.defaultloader` keeps the module block of the first parsed file, the
canonical main.

Consequently a comment placed between a doc block and its declaration, or
directly after a doc block, changes or detaches the attached document. This
matters for code back-link comments in `.titan` sources and for the
`spec/fixtures/stdlib/titan_stdlib_types.lua` fixture.

`documentation.parse(text)` splits a block into prose and `@name value` tags.
A tag value continues over the following lines, keeping indentation. The
summary is the prose up to the first `.` or `?` followed by whitespace, or
else the first line; the rest is the description.

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
type-member names to documents. `documentation.serialize` and
`serialize_map` render the same contract as deterministic Lua literals.

## Binding to declarations

Parser declarations retain `_documentation`. The signature visitor calls
`documentation.bind_declaration` before body analysis, which places documents
on declaration identities: `Type.Record`, `Type.Union`, `Type.Interface`,
`Type.Method`, and `Type.StaticMethod` for owners and members, and the
`Type.Field`/variant identity of each member. An owner's `@field name text`
tag supplies a member's document only when the member has no direct comment.
A synthesized record or union constructor without its own document gets one
built from its owner and variant (`constructor_documentation`), including
`@param`/`@return` tags and the owner's and variant's `@usage`/`@see` tags; an
`@field` document inherits the same tags from its owner. Module assembly
(`makemoduletype`) copies documents to `Type.ModuleMember`/`Type.ModuleVariable`
and places module documentation on `Type.Module._documentation`.

Transparent aliases and Interfaces, the module's type members, use a separate
named map, `Type.Module._type_documentation`. Decorating an alias's resolved
target would attach one alias's documentation to unrelated declarations that
share that target. Public metadata filters the map to exported type members;
compact source manifests also retain private alias documentation for direct
source imports.

`documentation.for_node(node)` returns the document for an AST occurrence or
its declaration. It follows `_decl`, `_method`, and `_field`, resolves import
bindings through their `Type.Module`, and uses the named map for qualified
type members (`Checker.TypeMember`). It never infers documentation from an
expression's result type. Generic rewriting copies documents without attaching
AST edges to rewritten descriptor graphs.

## Persistence and language-server integration

`types.serialize` wraps any descriptor carrying `_documentation` (or a module
with a non-empty filtered `_type_documentation`) as
`Documented(constructor, document, optional_named_map)`; undocumented
descriptors serialize unchanged. `types.Documented` accepts documents only on
declaration identities (`Type.Module`, `Type.ModuleMember`,
`Type.ModuleVariable`, `Type.Record`, `Type.Union`, `Type.Interface`,
`Type.Method`, `Type.StaticMethod`, `Type.Field`, `Type.Variant`), and a named
map only on a module whose type members contain every name. Thus the dynamic
`_types` protocol, static-provider and object metadata, embedded interfaces,
and the captured completion binary catalog all carry the same documents.
Source-interface fingerprints include documentation on private members and
aliases, so `.titan` importers invalidate their saved editor facts after
documentation edits.

`types.serialize_semantic` raises a suppression counter around
`types.serialize`, so documentation is excluded from source/compiled semantic
comparisons, binary-compatibility requirements, and every runtime
metatable/callable tag. Runtime reflection never sees editor documents; they
exist only in module-interface metadata.

Compact and encoded project entries keep documents in their closed
declaration schemas and scalar completion facts. `completion.describe(entry)`
exports module and candidate `documentation`, and completion observation
exports candidate documentation after resolving the real specialized
declaration ([Completion](completion.md)). Hosts validate the detached
subrecord at their compiler boundary, render Markdown once, and store scalar
text. `driver.completion_binary_catalog` also exports module documentation for
already selected provider siblings, preserving ordinary
source/embedded/static selection precedence. Metadata without documents
remains valid.

Focused regressions live in `spec/documentation_spec.lua`, with the native
reflection regression in `spec/coder/documentation_spec.lua`; the completion
and project-cache suites check their broader contracts.
