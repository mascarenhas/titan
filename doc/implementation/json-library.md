# JSON-library implementation

The public contract is [JSON standard library](../language/standard-library-json.md).
`titan.json` is one folder module with an explicit Make source inventory:

| Contributor | Responsibility |
| --- | --- |
| `titan/json/json.titan` | Public errors/options/entry points, per-call settings, private nodes and paths, common failure formatting, one module initializer |
| `titan/json/parser.titan` | Compiled Relabel grammar, recognition budgets, delayed node folds, string decoding, labeled syntax failures |
| `titan/json/decoder.titan` | Dynamic and descriptor-directed conversion, record and union constructors |
| `titan/json/writer.titan` | UTF-8 validation/escaping, compact output, cycle/limit checks, reflected value traversal, byte-sorted Map keys |
| `titan/json/numbers.titan` | Exact decimal-to-integer conversion, finite float conversion/formatting, narrow C numeric-locale boundary |

All contributors share one namespace. Public declarations belong to the main;
contributor declarations are local. No parser, native helper, or node becomes
an independently imported module. The implementation uses the public `peg`,
`reflect`, `string`, `math`, and `iteration` modules without a new JSON runtime
allocation primitive or third-party JSON dependency.

## Whole-document PEG

The main initializer stores `build_json_pattern()` (`parser.titan`) in
`JSON_PATTERN` once. `parse_document` reuses it with anchored
`Pattern:match(source, 1, budget)`. The start rule owns leading whitespace,
one value, and an explicit end assertion. Module-level `peg.match` would search
and discard the labeled failure protocol, so it is not the entry point.

Value alternatives are distinguished by their leading byte. After a selected
prefix, required continuations carry committed labels: a key after a comma,
a colon after a key, a separator after a value, digits after decimal/exponent
markers, and individual bytes of a literal. Whitespace is the four explicit
JSON bytes, independent of the PEG locale. Every repeated sibling body
consumes input; recursion follows container nesting rather than list width.
The grammar does not recover and retry after a syntax error.

String recognition accepts ASCII non-control bytes and UTF-8 scalar ranges,
excluding surrogate code points. Escape recognition commits after the
backslash and each required Unicode hex digit. A completed string capture is
decoded once into a writer; surrogate-pair checks retain the offending escape's
source position. Number captures retain start/end positions into the source,
so conversion happens only after the requested descriptor is known.

## Folds, budgets, and ownership

Every JSON value produces exactly one nonnil private `Node`. A null node stays
nonnil until conversion. Array nodes hold dense `{Node}` children; object nodes
hold dense `{Member}` entries and fresh typed parse state containing a
decoded-name set and one pending key node. A `Member` retains its
key name, key position, and value node. This preserves source positions, duplicate
members, trailing nulls, and the distinction between missing and explicit null.

Containers use ordinary delayed PEG fold captures. A seed capture creates a
fresh private Array/object node on each evaluation; a reducer accepts that node
and one captured node, updates its dense storage, and returns it. The object
grammar emits a key node and a value node as separate sibling captures; its
reducer retains the key until the next call constructs the `Member`. This avoids
an extra delayed-capture recursion layer around every nested member value.
The final
accumulator is the container node. No callback receives the entire list as a
flexible argument run, so widths above the ordinary capture-argument boundary
do not require eager materialization or an imperative stack of builders.

The seed is a position capture plus factory, not a constant holding a mutable
object created during grammar initialization. Delayed capture callbacks need
not execute exactly once in general. Here their mutation is restricted to
fresh private accumulators, and abandoned results do not escape. The object
reducer checks duplicate decoded names, including escaped spellings and names
whose earlier value was null.

A separate fresh `ParseBudget` (`parser.titan`) is passed through
`peg.argument(1)`, bound as the grammar's `state` definition. Small local
match-time callbacks count values and enter/leave containers. Their only result
is match success; they do not retain one dynamic capture result per child.
Guards are on committed paths and do not mutate state in predicates or in an
alternative that can ordinarily fail afterward. No callback yields. A failed
attempt discards its budget. A private `ParseFailure` raised by a guard or
semantic capture is converted to the same public error as a grammar label;
unrelated runtime exceptions propagate unchanged.

Folds bound callback argument/result space with respect to width. The engine's
capture records, private tree, and decoded output still require space
proportional to input values; this API parses a whole string and makes no
streaming-memory promise. Recognition limits run before delayed construction
can create an oversized result tree.

## Locations and complexity

An anchored failure returns `(nil, label, position)`. The successful capture is
a nonnil `Node`, so it cannot be confused with that failure triple even when
the JSON root is null. Labels retain their exact throw positions. They are
placed at the expectation itself rather than around a large failing rule:
`p / %{label}` rewinds a failed `p` before throwing. Throws outside lookahead
retain labels; predicates suppress them.

`json_fail` formats the path and calls `peg.line_column(source, position)` once
for a located failure. Paths are retained as private parent-linked components
during traversal and materialized only when an error is raised. Successful
parsing/conversion does not repeatedly scan source prefixes or concatenate
growing diagnostic strings. Byte positions, CR/LF/CRLF treatment, and EOF
positions are shared with the PEG module; columns count bytes, not display cells.

Recognition and node construction perform bounded work per consumed byte/node:
disjoint value prefixes, one whitespace owner, iterative sibling tails, one
string decoding pass, and constant-arity fold steps. Neither lookahead nor
ordinary choice reparses an entire nested value. Duplicate-name Maps have
their normal expected/amortized lookup cost; this is not a collision-resistant
worst-case hashing guarantee. Exact numeric conversion also scans its bounded
token, without looping according to an unbounded exponent value.

The parser's linearity claim is separate from reflected schema traversal and
encoding. In particular, deterministic Map output sorts keys with a bottom-up
byte-order merge sort (`writer.titan` `sort_keys`). It does not promise linear-time encoding of arbitrarily wide
objects.

`max_depth` accepts positive integers and defaults to 32 (`json.titan`
`default_settings`); it is an explicit
container budget, not an upper bound on the independent execution resources
needed by every accepted document. Nesting consumes both PEG matching-stack
space and native delayed-capture recursion space, plus decoder/writer traversal
space. JSON never changes `peg.set_max_stack` as a side effect of a call or
relabels an independent engine/runtime failure. Applications own the shared PEG
stack policy: sibling repetitions can retain more matching-stack entries than
single-child chains at the same depth. Tests exercise arrays and objects at 128
with the default stack, mixed nesting with siblings at 128 with an explicitly
configured stack, and rejection at an explicit smaller JSON budget. Width and
nesting tests cover separate boundaries.

## Exact scalar conversion

The grammar validates decimal JSON syntax before any numeric helper runs.
`number_value` chooses exact integer conversion for integer targets and dynamic
integer-form tokens. Fraction/exponent tokens default to float; an explicit
float target can consume any syntactically valid decimal token.

`decimal_integer` separates sign, coefficient, fraction length, and exponent.
It strips leading zeros, removes fractional trailing zeros when necessary,
and rejects non-integral or out-of-range values before a checked negative
accumulation. Negative accumulation includes the asymmetric minimum integer.
Exponent accumulation saturates beyond the range that could affect the bounded
token, avoiding overflow or work proportional to the mathematical exponent.
The path never uses a rounded binary float to decide integer equality.

`decimal_float` adapts the grammar-approved decimal point to the active numeric
locale before calling C `strtod`; it rejects nonfinite results and nonzero
coefficients that underflow to zero. `float_text` formats with sufficient
decimal digits, restores the JSON decimal point, and adds a fractional marker
when needed to preserve the float kind. These helpers read the locale's
conventions and do not call process-global `setlocale`. Their ordinary FFI
imports stay private to the module. The compiler retains the usual rooting
for strings while native functions read their bytes.

## Reflection conversion

Encoding dispatches through `reflect.inspect`. Container variants carry their
original storage directly in their `value` part; record and Interface schemas are selected
through `.type.fields`. Field access uses one-based public descriptor ordinals.
Storage indices are not getter ordinals.
Interface encoding reads the captured public view, not `.wrapped`. Union
encoding searches public variants for the actual runtime `.tag`; descriptor
positions cannot be inferred from sparse runtime tags. Private active arms
raise instead of inventing a name.

Decoding uses a caller-supplied `reflect.Type` or the dynamic schema. Named
targets use checked `reflect.find_nominal` and fail if the owner has not been
registered. They do not use `NamedType:resolve`'s fallback to `is_value`.
Nominal references are resolved lazily, so recursive schemas do not need
eagerly expanded cyclic descriptor shells. Reflection's generic erasure remains
visible: erased value leaves decode dynamically, with no specialization registry
or implied proof from the result's outer nominal identity.

Record decoding (`decoder.titan` `Decoder:decode_record`) locates the reflected
static `new` and verifies that it takes fixed
parameters and returns exactly one value of the target record's nominal type.
Absent constructors, input varargs, flexible results, optional results, and
other result shapes raise `constructor_unavailable` before invocation. This
accepts compatible custom overrides without bypassing their bodies or assuming
that their parameters correspond to record fields.

It checks member names and presence and constructs a fresh argument Array in
the reflected parameter order. Missing nil-admitting arguments remain nil.
It keeps the declared arity separately and
calls `constructor.callable(...arguments[1, arity])`; ordinary `#arguments`
would lose trailing optional nils. The constructor initializes const and
mutable fields once. There is no partially initialized record, raw storage
write, or allocate-then-`RecordValue:set` stage.

Union encoding emits the configured discriminator (default `tag`) followed by
parts in `VariantType.parts` order. `UnionValue:get(i)` supplies correctly
boxed values, including Arrays and nil parts. Union decoding finds the
configured discriminator independently of source member order, validates its
public variant name and exact envelope membership, and maps each remaining
key to a part name. The unnamed single-part syntax supplies the name `value`,
so legacy envelopes follow the same path. Missing nil-admitting parts stay
nil; required missing parts fail. Preserve explicit arity when invoking the
variadic reflected callable, including an all-nil argument Array.

`EncodeOption.tag_field` and `DecodeOption.tag_field` share the Settings
string field, apply to nested unions, and use last-option-wins semantics.
Before part traversal, reject a selected variant whose part name collides with
the configured discriminator. Do not emit duplicate JSON keys or silently lose
a payload part. Extra envelope fields are never covered by the record-only
`ignore_unknown_fields` option. Discriminator values count as ordinary JSON
nodes; part keys add no node or container depth of their own.

Array/Map conversion writes at each source index/key. It does not append based
on a result length that may have shortened after a nil. Dynamic nulls use the
configured sentinel, while Option/nil targets and concrete container holes
retain nil. The newly built mutable Array's storage has the `value` Lua-writer
policy; later typed reads enforce their own guards. Const targets use the
ordinary mutable-to-const conversion, and maybe-const targets return mutable
Arrays. Compiler-owned boxing, nominal checks, write barriers, and traced
callable ownership handle all constructed values.

## Writer and resource policy

Each encoder owns its settings, writer, output byte/node counters, and active
ancestor set. Sentinel comparison happens before ordinary dispatch, through
raw `value` equality, and never applies to object keys or generated tags.
Record fields and Array elements are visited in their established order.
Map entries are enumerated without `__pairs`, and keys must carry the actual
string tag; byte-order sorting is independent of numeric/string locale.

Ancestor membership detects cycles by identity. Removing a completed owner
allows a shared acyclic child to appear elsewhere in the output. The operation
does not call application codec callbacks. Escaping writes bounded chunks into
`string.writer()` and checks output growth before accepting them. Counters use
overflow-safe limit comparisons. Encoding reports no input location; located
parse/schema/numeric errors share byte/line/column formatting.

## Publication and validation

JSON is one ordinary logical root of the combined standard-library provider,
reached from Lua as `require "titan.json"` through the Titan package searcher;
there is no child DSO or independent LuaRocks C-module owner. Image layout and
publication are in
[the standard-library image](multi-module-libraries.md#reserved-titan-and-the-standard-library-image).

Public behavior lives under `spec/stdlib/titan/json/tests/`, as the explicit
`json.tests` root of the native aggregate, without LuaCov. Packaging/native-build
specs own exact sources, module protocols, metadata fixtures, and the installed
provider. Lua/provider and static production smokes exercise dynamic decoding,
null preservation, and a reflected record/union constructor composition.

The native suite covers syntax labels and positions, null/presence behavior,
numeric/Unicode boundaries, nominal and const mappings, cyclic versus shared
data, and limits. Wide containers above 32767 children exercise fold width;
deep containers exercise matching and capture recursion. Warmed doubling-size
measurements include successful documents and malformed input near EOF, and
support the structural complexity review without imposing fragile timing ratios
as correctness assertions. JSON's focused sanitizer selection checks the same
public allocation and lifetime behavior in the instrumented provider.

The [Titan JSON skill](../../.agents/skills/titan-json/SKILL.md) contains
agent-facing recipes and maintenance routing.
