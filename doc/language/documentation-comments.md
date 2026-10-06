# Documentation comments

Titan retains LDoc-style documentation for modules, top-level declarations and
interface methods. Editors use this metadata for hover and completion details.
Comments have no effect on runtime behavior, type identity or binary compatibility.

A documentation block starts with at least three hyphens. Following lines start
with two hyphens. The first sentence, ending in a period or question mark, is the
summary; remaining prose is the description. Markdown may appear in either.
If no sentence terminator is present, the first line is the summary.

```titan
--- Integer utilities. Operations on small counts.
-- @module counts

--- Add two counts.
-- @param left First count.
-- @param right Second count.
-- @return Their sum.
-- @usage arithmetic.md#addition
function add(left: integer, right: integer): integer
    return left + right
end
```

Use `@module` in a leading comment block to identify module documentation. Its
name is descriptive: the compiler's source resolver remains the authority for
module identity. A leading block without `@module` documents the following
declaration. For a folder module, the main source file supplies module
documentation; contributors supply documentation for their declarations.

A physical blank line closes a comment block; an explicit `--` blank comment
line preserves a paragraph inside it. A block attaches to the next declaration
separated only by whitespace. Supported
identities include variables, functions, records, unions, interfaces, type
aliases, static functions and methods, including local declarations. Record
fields, union variants and interface fields may also have their own blocks;
interface methods use the same syntax as ordinary functions:

```titan
--- A readable counter.
interface Counter
    --- Read the current count.
    -- @return Current value.
    function read(): integer
end
```

The block-comment spelling from LDoc is supported too, including matching Lua
long-bracket levels:

```titan
--[[-- Reset a counter.
@param counter Counter to reset.
]]
function reset(counter: integer): integer
    return 0
end
```

Tags begin at the start of a comment line, after indentation, with `@name`.
The compiler preserves each tag's name and text in source order. Repeated tags,
multiline descriptions, indented examples and unknown tags are retained.
Common tags include `@param`, `@tparam`, `@return`, `@treturn`, `@field`, `@raise`,
`@see`, `@usage`, `@deprecated`, `@author` and `@license`. Titan's signatures
already supply types and names, so duplicate type annotations are optional.
An owner-level `@field name Description.` supplies a field's documentation when
that field has no explicit block, inheriting the owner's `@usage` and `@see`
links. Documented records and union variants also
supply documentation for their generated constructors, including their usage links.

For standard-library members, `@usage` contains a Markdown document path relative
to `doc/language`, optionally followed by an anchor, for example
`standard-library-string.md#compiled-regular-expressions`. The editor resolves
that path when presenting it; persisted compiler metadata keeps the relative
spelling. Other consumers may choose their own presentation.

Ordinary comments, comments inside function bodies and strings that resemble
comments do not document top-level declarations. LDoc configuration files,
colon-style tags, static documentation generation and LDoc symbol-link resolution
are outside this metadata feature. See the
[LDoc manual](https://github.com/lunarmodules/ldoc/blob/master/manual.md) for the
conventions on which this syntax is based.
