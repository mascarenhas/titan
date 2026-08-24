# PEG and regex-backed string standard libraries

Status: accepted specification; implementation complete on
`agent/peg-string-standard-library`.

Delivery waiver: the maintainer explicitly waived the manual macOS
`workflow_dispatch` run for this feature. Exact-head Linux, sanitizer, and
Codecov evidence remain required before completion.

This plan expands the informal `peg`/`string` standard-library brief into a
source-grounded design for the current Titan compiler, runtime, combined
standard-library provider, source-rock installer, and CI layout.

The feature and its API-cleanup follow-up have four inseparable deliverables:

1. A self-contained `titan.peg` binding to a privately embedded LPegLabel
   engine, plus a Titan port of `relabel.lua`.
2. A `titan.string` module whose `match`, `gmatch`, and `gsub` functions use a
   labeled, byte-oriented regular-expression dialect ported from
   `ta-regex/pegex.lua`, while `find` is a literal binary-safe byte search.
3. The rest of the practical Lua 5.5 string surface implemented in Titan, with
   C99 and the Lua C API used through the existing FFI where they are the
   appropriate primitive boundary.
4. A general `exp is T` expression that reports whether the corresponding
   written cast would succeed, used to remove cast-success raw-type probes from
   the PEG and string implementations without widening Titan's cast relation.

The two new logical modules join the existing seven roots in the one canonical
`titan.so`/`titan.a` provider. Programs using either module must not depend on
an installed `lpeglabel.so` or `relabel.lua`.

## 1. Executive decisions

The standard-library design uses Titan's existing opaque records, first-class
functions, `value` calls, closures, variadic inputs, flexible results, folder
modules, generic iterators, module initializers, and Lua C FFI. The follow-up
cleanup also adds one general language feature: `exp is T`, the nonraising
predicate twin of the written `exp as T` cast.

Use these decisions:

- Add exactly two public logical modules: `titan.peg` and `titan.string`.
  Titan source may use the short imports `import "peg"` and
  `import "string"`; Lua uses `require "titan.peg"` and
  `require "titan.string"`. Bare Lua `require "string"` remains Lua's own
  library.
- Implement both as folder modules. Folder contributors split the code without
  adding logical modules, metadata keys, shims, or separate native providers.
- Pin LPegLabel release `v1.6.2-1`, commit
  `912b0b9e8641074408ffc2259e069b188e0c717b`. Vendor its five C translation
  units and required headers, retain the upstream notices, apply an audited
  private namespace patch, and build one private regular archive.
- Flatten that private LPegLabel archive into the combined standard-library
  `titan.a` and force-carry it into `titan.so` through the existing `titanc -X`
  path. Do **not** add it to `titan-runtime/libtitan.a`, whose exact
  `titan.o`/`titan_coro.o`/`titan_uv.o` membership remains unchanged.
- Keep the rockspec's installed `lpeglabel` dependency. The compiler itself
  still requires external `lpeglabel` and `relabel`; the new guarantee is that
  compiled Titan programs and the installed standard-library providers do not.
- Give the embedded engine private C symbols, a private opener, private
  registry keys, and hidden visibility. Do not publish
  `luaopen_lpeglabel`, register `package.loaded.lpeglabel`, load a second DSO,
  or share pattern identity with an externally installed LPegLabel.
- Expose LPegLabel patterns as an opaque nominal `peg.Pattern` record holding a
  GC-traced local `value`. All composition is through named Titan functions.
- Translate the practical LPegLabel surface, including every constructor,
  grammar facility, labeled failure, and capture form needed by `relabel` and
  general clients. Keep the diagnostic-only `ptree` and `pcode` exports
  private.
- Translate the full pinned `relabel.lua` language and its convenience
  functions into `titan.peg`. Preserve its labeled syntax diagnostics, but
  raise a formatted string error with a stable label and the familiar
  line/column/source/caret form.
- Pin `ta-regex/pegex.lua` from master commit
  `857e48682791ba55c98a7dd99c5fc7d71c02597d`, not the older `v0.2` tag.
  Preserve its documented and tested dialect/match semantics while
  deliberately tightening unspecified class/brace escaping and fixing its
  confirmed parser, backreference, and group-count defects.
- The regex dialect is byte-oriented; its built-in character classes and word
  boundaries are ASCII. `titan.peg.utf_range` remains available for explicitly
  matching UTF-8 code-point ranges, but the regex syntax has no implicit UTF-8
  or Unicode mode.
- Invalid regexes raise a formatted string error containing a stable label,
  message, absolute one-based byte position, line, column, source line, and
  caret. Ordinary no-match remains an option/nil result and is not an error.
- Normalize public LPegLabel failure positions to absolute one-based subject
  positions. Upstream's relative failure position when `init != 1` is an
  implementation trap, not part of Titan's public contract.
- Do not reproduce `pegex.lua`'s import-time `setmaxstack(1000)` side effect.
  The engine starts with LPegLabel's state-local default of 400; callers may
  explicitly use `peg.set_max_stack`.
- Implement the practical Lua 5.5 string table:
  `byte`, `char`, `find`, `format`, `gmatch`, `gsub`, `len`, `lower`,
  `match`, `pack`, `packsize`, `rep`, `reverse`, `sub`, `unpack`, and
  `upper`, plus the requested `tostring`.
- Do not implement `string.dump` in this feature. Titan functions are native C
  closures rather than dumpable Lua bytecode, and delegating only Lua
  functions would create a misleading partial API.
- Give regex `gsub` an exact `(string) -> string` replacement callback. Call it
  once per accepted match with the whole match only, independent of captures,
  and require an exact string result. Retaining or deleting a match is explicit
  by returning the supplied string or `""`; regex `gsub` has no dynamic
  template/table replacement surface. The `titan.peg` relabel `gsub` uses the
  same exact whole-match callback contract; relabel's dynamic template,
  capture-index, table, and function forms remain syntax inside compiled
  expressions rather than overloads of the public function parameter.
- Add `exp is T` without widening Titan's explicit-cast relation. The checker
  accepts exactly the source/target pairs accepted for a written `exp as T`;
  the operand is evaluated exactly once, a cast mismatch returns `false`
  instead of raising, and the test performs no branch narrowing. Total casts
  test true, including `value is <function type>` because function-typed casts
  defer callability validation until invocation. Use `is` in the formatter and
  PEG relabel dispatch where cast success is the question, while retaining an
  exact integer-tag probe where relabel requires integer identity rather than
  integer castability.
- Implement `tostring` with `luaL_tolstring` through the FFI, not by looking up
  mutable `_G.tostring`. This preserves built-in Lua 5.5 conversion and
  `__tostring` semantics. `format`'s `%s` conversion shares that helper and is
  therefore the one other string operation that can invoke `__tostring`.
  No other ordinary string operation calls Lua's base or string libraries.
- Keep the standard-library ABI unchanged. Adding two logical modules changes the
  provider's key set, not the Titan native ABI. Do not add bespoke
  seven-to-nine or cross-ABI migration machinery: this prototype supports a
  clean install and reinstallation over the current generated layout, and
  users should clean stale installations when an ABI is bumped.

### 1.1 Review defaults

These are the only material product choices not literally fixed by the brief.
The plan uses the recommended column unless the maintainer changes it during
review.

| Question | Recommended contract used below | Alternative |
| --- | --- | --- |
| `string` breadth | All practical Lua 5.5 functions plus `tostring`; omit only `dump` | A smaller initial subset |
| Regex and PEG `gsub` replacement | Exact `(string) -> string` callback receiving the whole match | Dynamic Lua template/table/function replacement through `value` |
| `peg` breadth | Practical full LPegLabel/relabel binding; omit only debug printers | Regex-only subset |
| `gmatch` result | Iterate non-nil `RegexMatch` records; obtain whole/captures from methods | Lua-style capture tuple, which cannot safely represent an unmatched first capture as generic-for control |
| Embedded pattern identity | Private and deliberately incompatible with external LPegLabel userdata | Shared registry/metatable identity |
| Match failure offsets | Absolute one-based byte positions | Preserve upstream's relative offset quirk |
| Regex source compatibility | Preserve documented/tested pinned behavior; tighten unspecified escaping and fix malformed-input defects | Treat `pegex` only as inspiration for a new dialect |

## 2. Scope

### 2.1 In scope

- Vendored, reproducible, sanitizer-aware LPegLabel native build on Linux and
  macOS.
- Symbol, registry, loader, and package isolation from external LPegLabel.
- Opaque patterns; constructors; grammars; sequence, choice, difference,
  predicates, repetition, look-behind, labels, and every LPegLabel capture
  family needed by the pinned release.
- Variadic left folds for the operations corresponding to LPegLabel `*`, `+`,
  and binary `-`.
- Full Titan translation of pinned `relabel.lua`, including grammar syntax,
  definitions, labeled failures, captures, replacement suffixes, locale
  refresh, weak caches, and line/column diagnostics.
- A compiled `Regex` abstraction and Lua-facing top-level string search,
  matching, typed record iteration, and substitution.
- A documented byte-regex dialect, labeled compilation errors, empty-match
  progress, group spans, and replacement rules.
- The practical Lua 5.5 non-pattern string functions and requested
  `tostring`, implemented without calling Lua's string library.
- The `exp is T` language expression, using exactly the written-`as` cast
  relation, single evaluation, a boolean result, no mismatch exception, and no
  flow-sensitive narrowing.
- Dynamic and static-provider operation, clean source-rock installation,
  current-layout publication/rollback, licensing, docs, tests, CI grouping,
  and exact-head Linux/sanitizer/Codecov evidence. The maintainer has waived
  the manual macOS run for this feature.

### 2.2 Out of scope

- Replacing Lua's global `string` table or its string metatable.
- Publishing bare `lpeglabel`, `relabel`, `peg`, or `string` Lua module names.
- Adding LPegLabel to `titan-runtime/libtitan.a` or installing a separate
  LPegLabel archive/header as part of the Titan SDK.
- Removing the compiler's external LuaRocks dependency on LPegLabel.
- Interoperability between `peg.Pattern` and raw userdata from a separately
  loaded `lpeglabel.so`.
- A second DSO, symbolic or hard links, `objcopy` renaming, `-Bsymbolic`,
  package-loader tricks, or other identity/linker workarounds.
- LPeg `ptree`/`pcode`, LPeg 1.1 accumulator `%` captures that LPegLabel
  1.6.2 does not implement, or behavior from a newer LPeg release.
- Unicode regex classes, UTF-8-aware `.`, case-insensitive matching,
  lookarounds, lazy/possessive quantifiers, named captures, inline flags,
  hexadecimal/octal escapes, or multi-digit backreferences.
- Lua-pattern compatibility, a `plain` flag on `find`, or an option that
  switches between regex and Lua patterns.
- `string.dump`.
- General flow-sensitive type narrowing, a broader type-test relation than
  written `as`, or eager callability validation for function-typed casts.
- A binary-rock ownership model. Direct standard-library artifacts remain
  source-published outside the rock manifest.
- Windows support in this iteration.

## 3. Repository and upstream evidence

### 3.1 Existing Titan substrate

- `titan-compiler/parser.lua:40-56` already desugars the seven short standard
  imports. Adding `peg` and `string` is a table/test change, not a resolution
  redesign.
- A record with a local field is an existing opaque native-handle boundary.
  `peg.Pattern` and `string.Regex` can hide GC-bearing implementation values
  without publishing foreign types.
- Titan functions and Lua/C functions can be called through `value`, and
  variadic inputs/flexible outputs can represent LPeg's heterogeneous dynamic
  captures.
- Written `as` already centralizes the admissible explicit-cast relation and
  all of its run-time checks. `is` must reuse that relation and mirror whether
  the written cast would raise, without changing `types.compatible`, adding
  narrowing, or eagerly validating a function-typed value.
- Module variables may be declared as constant placeholders and filled by the
  final root initializer once per Lua state. `titan/coroutine.titan` and
  `titan/uv/uv.titan` already use this pattern.
- Folder modules combine contributors into one checker/codegen pass while
  preserving one logical module, initializer, object, metadata record, and
  shim. They are the intended way to split these two large implementations.
- `titan/uv/runtime.titan` already demonstrates binary-safe byte access,
  `memcpy`/`memcmp`, Lua-owned byte storage, and `lua_pushlstring` through the
  FFI. It is a model, not a dependency to move or import.
- The no-`main` linker already force-carries metadata-free `-X` archives into
  the DSO, flattens their members into the static provider, target-checks the
  objects, and gives static consumers the required second archive search.
  No new provider abstraction is needed.
- The publisher already commits shims and dSYM, then `titan.a`, and renames
  `titan.so` last; caught failures restore the current generated layout. The
  module list and current-layout assertions need extension, not replacement or
  a new migration framework.

### 3.2 Exact upstream inputs

Vendor and document these immutable revisions:

- LPegLabel
  [`v1.6.2-1`](https://github.com/sqmedeiros/lpeglabel/releases/tag/v1.6.2-1),
  commit
  [`912b0b9e8641074408ffc2259e069b188e0c717b`](https://github.com/sqmedeiros/lpeglabel/tree/912b0b9e8641074408ffc2259e069b188e0c717b).
  The rockspec lists exactly `lplcap.c`, `lplcode.c`, `lplprint.c`,
  `lpltree.c`, and `lplvm.c`.
- LPegLabel's pinned
  [`relabel.lua`](https://github.com/sqmedeiros/lpeglabel/blob/912b0b9e8641074408ffc2259e069b188e0c717b/relabel.lua).
- `ta-regex` master commit
  [`857e48682791ba55c98a7dd99c5fc7d71c02597d`](https://github.com/jugglerchris/ta-regex/tree/857e48682791ba55c98a7dd99c5fc7d71c02597d),
  specifically
  [`pegex.lua`](https://github.com/jugglerchris/ta-regex/blob/857e48682791ba55c98a7dd99c5fc7d71c02597d/pegex.lua).
  This is three commits newer than tag `v0.2` and contains working `$`
  anchoring.

The regex-to-PEG continuation construction follows Oikawa, Ierusalimschy, and
de Moura's PUC-Rio paper
["Converting regexes to Parsing Expression Grammars"](https://www.inf.puc-rio.br/~roberto/docs/ry10-01.pdf),
as cited by `pegex.lua`. Attribute that algorithm in the implementation manual
and translated source; the paper itself is not vendored code.

The LPegLabel C sources build cleanly against the repository's exact Lua 5.5.0
headers, and upstream `test.lua`, `testlabel.lua`, and
`testrelabelparser.lua` pass under that Lua. The six `ta-regex` test programs
also pass under Lua 5.5 when run with LPegLabel substituted for LPeg.

LPegLabel reports the string `LPegLabel 1.6.1` even at release `1.6.2-1`
because the upstream `VERSION` macro was not advanced. The public docs and
vendor manifest must report the pinned tag and commit separately rather than
inferring the vendored revision from that runtime string.

### 3.3 Confirmed upstream defects to fix

The translated regex compiler must add regression tests and clean diagnostics
for these source defects:

- `[]` and `[^]` crash during conversion.
- An unclosed `[` can fall back to a literal rather than fail at compilation.
- Class escaping for `]`, `-`, brackets, and braces is inconsistent.
- `{min,max}` accepts `max < min`.
- Malformed `{,n}` falls back to literal text.
- The backreference converter omits its continuation, so a suffix after
  `\1` can be silently ignored.
- A reference to a nonexistent group fails later as an internal LPeg error.
- A valid reference to a group skipped by the selected alternation path raises
  the native “back reference not found” error instead of becoming no-match.
- `numgroups` counts conversion visits under `+` and every counted-repetition
  rewrite rather than syntactic capture groups: a single group under `{0}`,
  `{2}`, `{2,}`, and `{2,4}` is reported as 0, 2, 3, and 4 respectively.
- All parser failures collapse to a positionless generic error.

These are not compatibility behaviors.

## 4. Logical module and provider design

The dependency graph is intentionally one-way:

```text
vendored private LPegLabel C archive
                  |
                  v
             titan.peg
                  |
                  v
            titan.string
               /     \
              v       v
         titan.net  titan.os

titan.coroutine --> titan.uv --> titan.async
                         |-----> titan.timer
                         |-----> titan.fs
                         |-----> titan.net
                         `-----> titan.os

all nine logical roots --> titan.so + self-describing titan.a
```

`titan.peg` must not import `titan.string`; the relabel translation contains
small private byte slicing, line splitting, decimal parsing, and diagnostic
formatting helpers to avoid a cycle. `titan.string` may import `peg`, and
both `titan.net` and `titan.os` use its literal find and byte slicing.

The canonical provider now has:

- nine requested source roots;
- nine logical ABI/types protocols;
- nine embedded `titan.a` metadata keys;
- nine generated Lua shims;
- ten `luaopen_*` entries in `titan.so`: the nine logical modules plus bare
  `luaopen_titan` support.

The root request order is deterministic and stable:

```text
titan.coroutine
titan.uv
titan.async
titan.timer
titan.fs
titan.net
titan.os
titan.peg
titan.string
```

`peg` precedes `string`; otherwise preserve the current seven-root order so
existing declaration and archive order changes only by appending the two new
modules. This is not a topological order: while processing `titan.net` and
`titan.os`, the compiler recursively loads their `titan.string` dependency
(and in turn `titan.peg`) before those modules appear later as explicit
requested roots.

Recommended source layout:

```text
titan/
  peg/
    peg.titan                 # canonical main, public records, imports, initializer
    combinators.titan
    native.titan
    relabel.titan
    relabel_parser.titan
  string/
    string.titan              # canonical main, public records, peg import, initializer
    bytes.titan
    format.titan
    pack.titan
    regex_api.titan
    regex_compile.titan
    regex_parser.titan
```

The exact contributor split may change to keep files coherent, but it must not
create additional logical modules. Each canonical main owns the complete
public API, every contributor has only module-local top-level declarations,
and the main owns every module variable needed by contributors plus the sole
final initializer.

Because `string` is a Titan type keyword, examples use an alias:

```titan
local str = import "string"
local first, last = str.find("alpha-42", "-")
```

## 5. Private LPegLabel embedding

### 5.1 Vendor snapshot

Add a tracked `vendor/lpeglabel/` snapshot containing:

- the five exact upstream C files and all headers they include;
- test-only pinned copies of `test.lua`, `testlabel.lua`,
  `testrelabelparser.lua`, and the `relabel.lua` those suites load;
- upstream `LICENSE`, relevant retained copyright headers, and an
  `UPSTREAM.md` manifest;
- the exact tag, commit, source URLs, imported file list, archive checksum,
  local patch list, and verification commands;
- a small private declaration header for the renamed opener;
- no generated objects or archives.

The upstream `relabel.lua` copy is a test fixture only. The private-opener
harness redirects its `require "lpeglabel"` to the namespaced engine and loads
that exact fixture; none of these four Lua files is installed, published as a
module, or used by production. The production relabel implementation is the
reviewed Titan translation.

### 5.2 Namespace patch

Unmodified upstream objects export generic cross-translation-unit symbols such
as `compile`, `match`, `fixedlen`, `runtimecap`, `sizei`, `getcaptures`,
`realloccode`, `numsiblings`, and `luaopen_lpeglabel`. Since `titan.so` is
promoted with `RTLD_GLOBAL`, and `titan.a` is flattened into static consumers,
visibility alone is insufficient.

The vendor patch must:

- prefix every defined external symbol, including debug-conditional symbols,
  as `titan_lpeglabel_*`;
- rename the opener to `titan_lpeglabel_open`;
- compile all five units with hidden default visibility;
- rename `PATTERN_T` and `MAXSTACKIDX` registry strings to Titan-private,
  revisioned names such as
  `titan.peg.lpeglabel.912b0b9e.pattern` and
  `titan.peg.lpeglabel.912b0b9e.maxstack`;
- keep internal static functions static;
- retain upstream source readability and make the patch mechanically
  auditable in `UPSTREAM.md`.

Apply the prefix in source/shared headers, not with `objcopy`, linker aliases,
or platform-specific symbol rewriting.

The private engine table is created by directly calling
`titan_lpeglabel_open(L)` once from `titan.peg`'s module initializer. The
returned table is rooted in the module state. Do not call `luaL_requiref`, set
`package.loaded`, or expose the table itself.

### 5.3 Native archive build

Build a regular archive such as:

```text
lpeglabel-build/libtitan-lpeglabel.a
```

with exactly five objects in upstream rockspec order. Add content/configuration
stamps that record:

- vendored tag/commit and the hash/list of every source and header;
- symbol-prefix and visibility policy;
- host platform and target-affecting flags;
- effective `CC`, `AR`, and `RANLIB`;
- exact `ROCK_LUA_INCDIR`, configured `luaconf.h`, and source-build
  `ROCK_CFLAGS`;
- explicit C99/PIC/hidden-visibility flags plus effective
  `TITAN_EXTRA_CPPFLAGS` and `TITAN_EXTRA_CFLAGS`, including sanitizer and
  target selection;
- archive member order and deterministic-tool mode.

Use the configured commands parsed by the existing Make conventions. Prefer
deterministic `ar qDc`/`ranlib -D`, use the existing portable fallbacks, then
rescan the archive and exact ordered member manifest. A successful exit status
without correct membership is not completion.

The native archive is always part of `STDLIB_EXTRA_OBJECTS`:

```text
bundled libuv: titanlib.o + libtitan-lpeglabel.a + private libuv.a
system libuv:  titanlib.o + libtitan-lpeglabel.a
```

It is not copied to `$ROCKS_TREE/lib`, and its headers are not staged under
`$ROCKS_TREE/include`. The source-rock post-install build sees the vendored
source tree directly and passes its exact include directory only while
compiling the standard modules.

`make clean` removes only the private LPegLabel objects, archive, and stamps.
`make distclean` retains the tracked vendor snapshot. Never add a broad archive
glob.

### 5.4 Isolation proofs

Automated tests must establish all of the following:

- Platform-normalized `nm` over the private archive finds no unprefixed
  defined upstream symbol; normalize Darwin's leading underscore.
- Defined symbols in the private archive are either local or begin with
  `titan_lpeglabel_`.
- Dynamic-symbol inspection of `titan.so` does not export
  `luaopen_lpeglabel` or the private opener.
- Ordinary-symbol inspection of `titan.a` finds no unprefixed LPegLabel
  definition.
- `readelf` on ELF and semantic parsing of Mach-O `LC_LOAD_*` commands from
  `otool -l` show no LPegLabel dynamic dependency.
- `titan.peg` works with Lua search paths that contain the Titan shim/provider
  but no `lpeglabel.so` or `relabel.lua`.
- External LPegLabel and `titan.peg` can be loaded in both orders in one Lua
  state; each continues to match its own patterns, registry identity and
  `setmaxstack` state remain independent, and cross-engine patterns are
  rejected cleanly.

## 6. `titan.peg` public contract

### 6.1 Opaque types and errors

The public shape is conceptually:

```titan
record Pattern
  local raw: value
  local tree_size: integer
end

record Rule
  local name: value
  local pattern: Pattern
end

record Definition
  name: string
  local raw: value
end

local record SyntaxDiagnostic
  label: string
  message: string
  source: string
  position: integer
  line: integer
  column: integer
  source_line: string
end
```

`Pattern` and `Rule` have no public constructors and never expose raw native
userdata or unvalidated grammar entries.
`tree_size` supports the conservative construction bound in section 6.7 and
is never caller-mutable. Titan deliberately restricts `Rule.name` to a string
or integer at run time; the native grammar accepts arbitrary non-nil Lua keys,
but that extra dynamism has no useful typed contract here. Duplicate names,
non-dense rule collections, and a missing start rule raise ordinary argument
errors before entering the native engine.

Records cannot define custom metatables in Titan, so the internal diagnostic
record is not raised directly. The compiler formats and raises this string:

```text
PEG syntax error [ExpPatt1] at L2:C7 (byte 19): expected a pattern after '/'
<source line>
      ^
```

The label, byte position, line, column, message, source line, and caret are the
stable public diagnostic contract. All positions are one-based byte positions.
CRLF is one line ending; the caret points at the relevant byte or one past the
line at EOF. A caught `error: value` therefore contains an ordinary string,
matching Titan's existing user-facing error convention.

### 6.2 Constructors

Use descriptive names in place of LPeg's overloaded `P`:

| Titan function | LPegLabel operation | Contract |
| --- | --- | --- |
| `literal(text: string): Pattern` | `P(string)` | Exact binary string |
| `any(count: integer?): Pattern` | `P(integer)` | Nil/omitted means 1; `count >= 0`: exactly that many bytes; negative: succeeds only when fewer than `-count` bytes remain; checked against the construction-size policy before native integer narrowing |
| `succeed(): Pattern` | `P(true)` | Empty success |
| `fail(): Pattern` | `P(false)` | Ordinary failure |
| `runtime(callback: (string, integer, string) -> (...: value)): Pattern` | `P(function)` | Callback receiving subject, current absolute position, and the empty whole-match string through an internal native adapter |
| `set(bytes: string): Pattern` | `S(string)` | One byte from the set |
| `ranges(...: string): Pattern` | `R(...)` | Each argument is exactly two bytes; zero ranges is failure |
| `utf_range(first: integer, last: integer): Pattern` | `utfR` | Byte encodings for the inclusive code-point range `0..0x10ffff`; matching native `utfR`, this includes surrogate code points and is not Unicode-scalar validation |
| `variable(name: value): Pattern` | `V` | Open string/integer grammar reference |
| `rule(name: value, pattern: Pattern): Rule` | grammar table entry | Validated string/integer named/recovery rule |
| `grammar(start: value, rules: {integer: Rule}): Pattern` | `P(table)` | Keys must be exactly dense `1..N` with no extras, accepting a Titan Map or ordinary Lua table; at most pinned `MAXRULES == 1000`; converted to one private ordinary Lua grammar table |
| `behind(pattern: Pattern): Pattern` | `B` | Capture-free fixed length at most pinned `MAXBEHIND == 255` bytes |
| `throw(label: value): Pattern` | `T` | Type-tagged string/integer labeled failure |

`grammar` validates `start` with the same string/integer rule as each
`Rule.name`. The typed constructors intentionally replace LPeg's general
coercion. Pattern arguments do not silently coerce strings/numbers; callers
choose the explicit constructor. `runtime` uses a callable type with a
flexible heterogeneous result because its callback may fail with no result or
return a success/position followed by captures; the callback itself does not
need to be hidden behind an unqualified `value`. Pinned LPegLabel implements
`P(function)` as an empty runtime capture, so its ordinary no-nested fallback
supplies a third callback argument: the whole matched substring, always `""`.

Dense collection validation scans every raw Map/table key, requires positive
integer keys, tracks count and maximum, and then requires `count == maximum`;
it must not trust the unspecified `#` border of a holed integer Map or invoke
collection metamethods.

### 6.3 Operator substitutions and folds

The requested operator replacements are:

| Titan function | LPeg operator | Arity and order |
| --- | --- | --- |
| `sequence(...: Pattern): Pattern` | `p1 * p2` | Left fold; zero is `succeed`, one returns that pattern |
| `choice(...: Pattern): Pattern` | `p1 + p2` | Left fold; zero is `fail`, one returns that pattern |
| `difference(first: Pattern, ...: Pattern): Pattern` | `p1 - p2` | Left fold `((first - p2) - p3)...`; one returns `first` |
| `lookahead(pattern: Pattern): Pattern` | `#p` | Positive predicate |
| `negative(pattern: Pattern): Pattern` | unary `-p` | Negative predicate |
| `at_least(pattern: Pattern, count: integer): Pattern` | `p ^ n` | `count >= 0`, possessive |
| `at_most(pattern: Pattern, count: integer): Pattern` | `p ^ -n` | `count >= 0`, possessive; zero is special-cased to `succeed()` because native `-0` would mean `p ^ 0` (zero-or-more) |
| `zero_or_more(pattern: Pattern): Pattern` | `p ^ 0` | Convenience |
| `one_or_more(pattern: Pattern): Pattern` | `p ^ 1` | Convenience |
| `optional(pattern: Pattern): Pattern` | `p ^ -1` | Convenience |

All three folds are positional. Titan variadic functions do not support named
calls, and named syntax would not improve these self-labeling operands.

LPeg's four overloaded `p / x` capture forms are exposed as the separately
typed capture constructors in section 6.4 rather than one loose
`replace(..., value)` operation.

Ordered choice catches only ordinary failure. A thrown label commits across
the remaining alternatives and repetitions. A throw inside a positive or
negative predicate becomes predicate failure rather than escaping. If a
grammar has a rule keyed by the label, that recovery rule begins at the throw
position and successful recovery resumes the original match.

### 6.4 Captures

Expose the pinned LPegLabel capture surface:

| Titan function | Native operation |
| --- | --- |
| `capture(pattern: Pattern): Pattern` | `C` simple substring capture |
| `constant(...: value): Pattern` | `Cc` constant captures |
| `match_time(pattern: Pattern, callback: (string, integer, value, ...: value) -> (...: value)): Pattern` | `Cmt` |
| `back_capture(key: value): Pattern` | `Cb` |
| `argument(index: integer): Pattern` | `Carg` |
| `position(): Pattern` | `Cp` |
| `substitution(pattern: Pattern): Pattern` | `Cs` |
| `table_capture(pattern: Pattern): Pattern` | `Ct` |
| `fold_capture(pattern: Pattern, callback: (value, ...: value) -> value): Pattern` | `Cf` |
| `group(pattern: Pattern, key: value): Pattern` | `Cg`; omitted/nil key means an anonymous group |
| `select_capture(pattern: Pattern, index: integer): Pattern` | `/` number |
| `template_capture(pattern: Pattern, template: string): Pattern` | `/` string |
| `query_capture(pattern: Pattern, lookup: {value: value}): Pattern` | `/` raw table |
| `function_capture(pattern: Pattern, callback: (value, ...: value) -> (...: value)): Pattern` | `/` function through a native adapter |

The public manual must document native timing precisely:

- ordinary captures may be evaluated zero, one, or multiple times and should
  not rely on side effects;
- runtime patterns and match-time captures run immediately and can affect
  matching; function captures are delayed until capture evaluation;
- `runtime`, `match_time`, `fold_capture`, and `function_capture` keep their
  declared function types, but do not eagerly raw-tag-check the supplied
  value: exact Titan functions use the exact call path, while Lua functions,
  C functions, and `__call` objects use Titan's generic callable path; a
  genuinely noncallable value fails only when the engine invokes it;
- a match-time callback receives subject, absolute position after its nested
  match, and at least one capture-side value: all nested captures, or the
  whole matched substring when there are none;
- its first result is false/nil/no result for failure, true for success at the
  current position, or an integer new position; later results are captures;
- a function-capture callback receives all nested captures, or the whole
  matched substring when there are none, and all of its results become
  captures;
- a fold callback receives the accumulator followed by every value produced
  by the next nested capture and returns exactly one new accumulator; its
  variadic tail may be empty when that later capture produces no direct value;
- LPegLabel 1.6.2 does not implement LPeg 1.1 accumulator `%` captures.

Upstream LPeg calls the `/ function` form a **function capture**. LPegLabel's
C internals use “dynamic capture” for the immediate runtime/`Cmt` mechanism,
so the public name `function_capture` avoids overloading that term and
distinguishes this delayed operation from `match_time`.

It must also make the delayed-capture value rules usable without consulting
LPeg's manual:

`group` accepts any non-nil key for a named group; omitted/nil selects the
anonymous form. `back_capture` requires a non-nil key.

- `capture(p)` returns the whole matched substring first, followed by nested
  capture values.
- An anonymous `group` returns its nested values directly, subject to the
  no-nested implicit rule below. A named `group` returns no direct value;
  `back_capture` returns every value of the latest matching named group and
  raises the documented native error when no such group exists.
- `table_capture` appends anonymous values at integer keys and stores a named
  group's first nested value at its name. `fold_capture` requires an initial
  capture value and folds each later capture left-to-right through the
  callback. If the first nested capture produces multiple values, only its
  first value initializes the accumulator.
- `substitution` replaces captured spans and copies unmatched bytes.
  `select_capture(p, 0)` discards captures; index `n` in `1..SHRT_MAX`
  selects the nth nested capture. `template_capture` supports native
  `%0..%9`; `query_capture` indexes its raw table by the first nested capture
  and honors `__index`; `function_capture` receives all nested captures and
  returns all of its results.
- `argument(n)` accepts `1..SHRT_MAX` and raises at match time if the
  corresponding extra argument is absent. Match-time and runtime-pattern
  callbacks must return a new position between the current position and one
  past the subject end (or the documented true/false protocol); wrappers
  reject out-of-range/nonnumeric positions without corrupting native state.

LPeg's implicit-whole-match rule depends on the capture operation. When `p`
has no nested captures:

| Wrapper | Result |
| --- | --- |
| anonymous `group(p)` | the whole substring |
| named `group(p, key)` then `back_capture(key)` | no direct group value, then the whole substring |
| `query_capture(p, table)` | lookup by the whole substring |
| `function_capture(p, callback)` | call with the whole substring |
| `select_capture(p, 1)` | the whole substring (`select_capture(p, 0)` still discards) |
| `template_capture(p, "%0")` | the whole substring; `%1` is invalid |
| `table_capture(p)` | an empty table |
| `fold_capture(p, f)` | error: no initial capture |

`match_time` receives the whole matched substring as its one capture-side
argument in this case, after its fixed subject/position arguments.

`query_capture` uses `{value: value}` because a Titan Map is the same ordinary
Lua table object: arbitrary keys/values, metatable identity, and `__index`
behavior are preserved when the native engine performs the lookup. It does
not need an unqualified `value` merely because the table contents are
heterogeneous. `function_capture` likewise has a callable type. Its wrapper
installs an exact internal closure for the native callback slot, captures the
supplied value, and invokes that value through ordinary Titan function-call
semantics. There is no `_raw_type` or eager raw-function check: callable
tables and userdata use the generic `__call` path, and a genuinely noncallable
value raises only if capture evaluation reaches it. A callable table remains
a query capture when passed to `query_capture`, because that parameter is
statically a Map rather than a function. `select_capture` uses an `integer`,
so Titan's normal boundary accepts representable integral floats and rejects
fractional/out-of-range values before the pinned C code narrows them; its
native range is `0..SHRT_MAX`.

Internal relabel and regex callbacks use fixed parameters when their
constructed capture shape is fixed. The public callback slots remain
variadic/flexible where arbitrary user patterns make the run genuinely open;
adjustment-aware callable compatibility admits the fixed helpers because their
additional `value` parameters accept both nil and the tail element.

### 6.5 Matching

```titan
function Pattern:match(subject: string,
                       init: integer?,
                       ...: value): (value, ...: value)
```

Nil/omitted `init` means 1. Matching is anchored at normalized `init`. A
negative `init` counts from the end, then clamps to the subject bounds as in
LPeg.

On success:

- return the captures when the pattern has captures;
- otherwise return the absolute one-based position after the match.

On ordinary failure:

```text
nil, "fail", absolute_farthest_position
```

On an uncaught labeled failure:

```text
nil, label, absolute_throw_position
```

The wrapper corrects upstream's `sfail - (subject + init) + 1` result by adding
the normalized initial offset. String and integer labels are preserved.

Initial positions deliberately preserve LPeg behavior while avoiding
`lua_Integer` negation overflow in the pinned C:

- nil means 1;
- a positive position selects that byte and anything above `#subject + 1`
  clamps to `#subject + 1`;
- zero means `#subject + 1`;
- a negative position counts back from the end (`-1` is the last byte), and a
  negative overshoot clamps to 1.

Normalize with checked Titan arithmetic, then pass a safe positive position to
the engine.

The method's fixed `value` prefix, flexible `value` tail, and extra match
arguments are subject to Titan's documented bounds. This is a language
boundary, not a smaller LPegLabel capture limit.

### 6.6 Locale and engine controls

Expose:

```titan
record Locale
  alnum: Pattern
  alpha: Pattern
  cntrl: Pattern
  digit: Pattern
  graph: Pattern
  lower: Pattern
  print: Pattern
  punct: Pattern
  space: Pattern
  upper: Pattern
  xdigit: Pattern
end

function locale(): Locale
function set_max_stack(maximum: integer)
function version(): string
```

`locale` snapshots the process's current C locale. `set_max_stack` changes only
the private embedded engine in the current Lua state and preserves the pinned
native range `1..INT_MAX/100`. `version` returns the engine's native string, while documentation and
the vendor manifest separately identify the exact pinned tag/commit.

Do not expose native `type`, `ptree`, or `pcode`. Static typing already
distinguishes `Pattern`; raw external pattern userdata is intentionally not
part of the API; the two printer functions are debug side effects.

### 6.7 Construction limits and label normalization

The pinned source defines `MAXPATTSIZE == SHRT_MAX - 10` but does not enforce
it consistently. Titan adopts that value as a conservative public policy, not
as a claim about the engine's exact representable maximum. Every constructor,
fold, grammar, predicate, capture, and repetition computes its projected tree
size with checked arithmetic before entering native code; every returned
`Pattern` records its actual/conservative size. This prevents allocator-size
overflow and the pinned code's early narrowing of Lua integers to C `int`.

Validate the native boundaries explicitly:

- positive `any(n)` needs `2*n - 1` nodes and negative `any(-n)` needs `2*n`;
- all repetition formulas, including the pattern operand size, must fit the
  policy cap; `at_most(p, 0)` never enters native `__pow`;
- `argument` accepts `1..SHRT_MAX`, `select_capture` accepts
  `0..SHRT_MAX`, `behind` accepts fixed capture-free lengths through 255,
  grammars accept at most 1000 rules, and `set_max_stack` accepts
  `1..INT_MAX/100`.

The wrapper intentionally fixes LPegLabel's numeric-label coercion quirk.
Public labels and grammar/recovery names are strings or integers and are
encoded as private type-tagged native strings. `"1"`, `"01"`, `1`, and `0`
remain distinct; a caught throw decodes to the original type, and only an
exactly equal public rule name recovers it. This is a documented Titan
divergence from native `T`, where numeric-looking strings may return integers
and numeric labels recover through string keys.

## 7. Titan `relabel` translation

### 7.1 Public surface

Keep relabel in `titan.peg`, not a third `titan.peg.re` logical module:

```titan
function define(name: string, pattern: Pattern): Definition
function define_value(name: string, candidate: value): Definition

record Match
  first: integer
  last: integer
end

function compile(candidate: value,
                 definitions: {integer: Definition}?): Pattern
function match(subject: string,
               candidate: value,
               init: integer?): Match?
function Match:values(): (...: value)
function gsub(subject: string,
              candidate: value,
              replacement: (string) -> string): string
function update_locale()
function line_column(subject: string,
                     position: integer): (integer, integer)
```

`Definition` is opaque because a pattern definition must store the private raw
pattern while other definitions can hold callables, tables, strings, or
numbers used by replacement and match-time suffixes. The two constructors
make that distinction explicit.

`candidate` must be a source string or this private engine's `Pattern`.
`compile` is identity for a pattern, matching pinned relabel; `match` and
`gsub` likewise accept either form. They weakly cache only
definition-free source strings. `gsub` returns only the transformed string,
matching relabel rather than `string.gsub`.

Module `match` searches leftmost at or after the normalized initial position
and returns nil or a `Match` whose public `first`/`last` are one-based and
inclusive. Empty success has `last == first - 1`. `Match:values()` returns
exactly the candidate captures—including nil and trailing-nil slots—and zero
values when there are no captures. This record is the position-and-capture
superset that replaces relabel `find`; anchored matching and native failure
triples remain on `Pattern:match`.

Implement the search over a private single-attempt result that retains the
after-position, exact capture count, and raw capture table. Reuse that result
both for `Pattern:match` projection and for module search. Do not wrap the
candidate with position captures or match twice: either would consume capture
capacity or repeat match-time side effects. A normal failure advances one byte
through `#subject + 1`; an uncaught labeled failure commits the search.

Public `gsub` takes only an exact `(string) -> string` replacement. It discards
candidate captures, calls the function with the whole matched byte string, and
inserts the returned string literally. Source candidates reuse the ordinary
weak compiled-pattern cache; callback-specific substitution wrappers are
short-lived per call.

Relabel expression `->` suffixes retain the source language's dynamic
definition values. Classify those suffix operands exactly once and in this
order: string, exact Lua-integer tag, Map, then unconditional function
fallback. The exact-integer probe deliberately does not classify an integral
Lua float as a selector. The Map test precedes the fallback so a table with
`__call` still has query semantics. Do not use `_raw_type` or another eager
callability test for the fallback: its adapter captures the dynamic definition
value and lets Titan's ordinary generic callable path reject it only if
capture evaluation actually invokes it.

As upstream does, `compile(pattern, definitions)` returns the pattern and
ignores the definition collection; definitions participate only while parsing
a source expression.

Nil/omitted `definitions` means an empty definition set, and nil/omitted
`init` means 1. Titan models optional parameters through nil-accepting types
and ordinary call adjustment; these declarations do not introduce
source-level default-argument syntax.

Module `match` uses section 6.5's LPeg initial-position table (including zero
meaning end and oversized positives clamping to end), not section 9's
Lua-string-style regex table.

Definitions use dense integer keys `1..N` with no extras, so both Titan Maps
and ordinary Lua tables can construct them. Names must be valid relabel
identifiers and unique. `define_value` rejects nil and false because pinned
relabel's truthy definition lookup treats them as absent; other values are
retained exactly. Invalid names and duplicates are rejected before building
the native definition table. Use the same raw key-scan/count/max validation as
`grammar`, never a table-border length.

Dynamic definition values consumed by runtime, match-time, fold, or function
suffixes use the same adapter discipline: the native engine receives an exact
closure for its protocol, while callability of the captured value is deferred
until that closure is invoked.

### 7.2 Expression language

Port the pinned grammar exactly:

- grouping, positive/negative predicates, concatenation, ordered choice;
- `?`, `*`, `+`, exact `^n`, at-least `^+n`, and at-most `^-n`;
- single/double-quoted literals, character classes, `.`, `%name` predefined
  and external definitions;
- multi-rule recursive grammars with `name <- expression`, bare names, and
  `<name>` nonterminals;
- position `{}`, simple `{ p }`, anonymous group `{: p :}`, named group
  `{:name: p :}`, substitution
  `{~ p ~}`, and table `{| p |}` captures;
- back captures `=name`;
- `-> string|number|{}|name`, `=> name`, and `~> name` suffixes;
- whitespace and Lua-style `--` comments;
- locale classes and short names `a,c,d,g,l,p,s,u,w,x`, uppercase
  complements, and `nl`;
- `%{label}` throws, where `label` is an identifier or decimal integer;
- `p^label` with an identifier immediately after `^` and no intervening space
  means `choice(p, throw(label))`; decimal `p^n` is repetition.

The translation must use the public named `peg` operations, not reach around
the wrapper to native metamethods from relabel code. This dogfoods the binding.

### 7.3 Caches and locale

Use one weak-value cache for definition-free source compilations shared by
`compile`, module `match`, and `gsub`, private per Lua state:

- create ordinary Lua tables with `__mode = "v"` through the Lua C API;
- root the tables in `titan.peg` module state;
- never hold unbounded strong references to compiled expressions, callbacks,
  or subject strings;
- keep a temporary strong local while a cache entry is in use;
- clear the cache when `update_locale` rebuilds predefined classes.

The relabel parser has its own private byte/string helpers and does not import
`titan.string`.

`line_column` intentionally repairs pinned `calcline` instead of preserving
its inconsistent EOF/newline offsets. It follows Titan's one-based byte,
CRLF-as-one-ending, and EOF-caret rules, and accepts positions only in
`1..#subject+1`. Document this divergence and keep the unmodified upstream
diagnostic snapshots in the private-opener compatibility harness, while
Titan-facing snapshots assert the corrected public form.

## 8. `titan.string` public contract

### 8.1 Module identity

`import "string"` desugars to `titan.string`, but `string` remains a type
keyword. Lua requires the qualified module. Loading Titan's module does not
mutate:

- `_G.string`;
- the Lua string metatable;
- `package.loaded.string`;
- Lua's native pattern functions.

### 8.2 Practical Lua-compatible surface

The public signatures are:

```titan
function len(subject: string): integer
function sub(subject: string,
             first: integer,
             last: integer?): string
function reverse(subject: string): string
function lower(subject: string): string
function upper(subject: string): string
function rep(subject: string,
             count: integer,
             separator: string?): string

function byte(subject: string,
              first: integer?,
              last: integer?): (...: integer)
function char(...: integer): string

function find(subject: string,
              needle: string,
              init: integer?): (integer?, integer?)

function format(format_string: string, ...: value): string
function pack(format_string: string, ...: value): string
function packsize(format_string: string): integer
function unpack(format_string: string,
                data: string,
                initial: integer?): (value, ...: value)

function tostring(candidate: value): string
```

Common rules:

- strings are binary and lengths/indices count bytes;
- public positions are one-based and inclusive;
- negative indices count from the end;
- `sub` and `byte` clamp zero and out-of-range indices exactly as Lua 5.5
  does; literal `find` uses the same initial-position normalization and returns
  one-based inclusive bounds or the fixed pair `nil, nil`; `unpack` normalizes
  zero and
  a negative overshoot to byte 1, accepts
  an initial position through `#data + 1`, and rejects a larger positive
  position instead of clamping it;
- arithmetic and allocation sizes are checked before conversion to C
  `size_t`; oversized results raise a stable error instead of wrapping;
- embedded NUL bytes are preserved except where Lua itself rejects them for a
  C-style format (`z`, modified `%s`, and similar documented cases);
- all input strings remain rooted across native borrows and all Lua stack
  changes are balanced on success and error.

“Lua-compatible” here means semantic parity for values admitted by the
published Titan signatures. Fixed `string` parameters require actual strings
instead of Lua's number-to-string coercion. Fixed `integer` parameters use
Titan's ordinary generated boundary: Lua integers and exactly integral,
representable floats are accepted, while fractional or out-of-range numbers
are rejected. Lua calls through generated Titan shims observe the same
boundary. Differential tests compare the admitted domain and separately assert
the strict-string and numeric-range boundaries.

The dynamic `value` slots of `format` and `pack` are different: after pushing
each value, use the exact Lua C conversion required by the current format
(`luaL_checkinteger`, `luaL_checknumber`, or `luaL_checklstring`) before the
Titan implementation consumes it. This preserves Lua's numeric conversions
and the number-as-string behavior of `c[n]`, `s[n]`, and `z`; do not implement
these slots as `value as string` or an ordinary Titan scalar cast.

Nil/omitted `last` in `sub` means -1; nil/omitted `separator` in `rep` means
the empty string; nil/omitted `first` in `byte` means 1; nil/omitted `last` in
`byte` defaults to the same raw supplied/defaulted `first` before each endpoint
is normalized (so `byte(s, 0)` and a negative overshoot return no values, as in
Lua 5.5); and nil/omitted `initial` in `unpack` means 1. An empty byte interval
returns no values. `char()` returns the empty string and every argument must be
in `[0,255]`.

Titan variadic/flexible tails have a 200-element bound. The string API also
caps projected result lists at 200 total values, including any fixed prefix.
Consequently:

- `byte` returns at most 200 byte values per call;
- `char`, `format`, and `pack` accept at most 200 variadic values;
- `unpack` returns at most 200 values including its final next-position value.

Crossing the bound raises Titan's standard variadic/flexible error. The manual
must state this alongside the existing language-wide limit rather than imply
unbounded Lua result lists.

### 8.3 `tostring` and the Lua-call boundary

`tostring` has one ordinary `value` parameter. Titan's existing call
adjustment supplies nil when the argument is omitted and ignores surplus
arguments, so there is no reason to make this API variadic merely to discard
extras. Consequently `tostring()` is the same as `tostring(nil)`, while
`tostring(first, surplus)` converts only `first`. The no-argument case is a
deliberate consequence of Titan's fixed-call semantics rather than Lua's
base-library arity error. As with every Titan call, surplus argument
expressions are still evaluated left-to-right before their values are
discarded.

Implement the conversion directly with:

1. save the current Lua stack top;
2. push the `TValue` represented by the Titan `value`;
3. call `luaL_tolstring`;
4. copy the exact byte string result into a Titan string;
5. restore the stack.

For the value it observes, this matches built-in Lua 5.5 behavior, including
numeric formatting, booleans/nil, and a callable `__tostring` metamethod. It
deliberately ignores later replacement of `_G.tostring`.

`format`'s `%s` conversion calls this same internal helper. It may therefore
run user `__tostring` code and propagate its error. This is the only additional
ordinary string function that needs Lua's conversion primitive.

Regex and PEG `gsub` may invoke their exact whole-match replacement functions,
while relabel expression suffixes and `peg` captures may invoke dynamic
definition callbacks or table metamethods. Those are explicit callback APIs,
not dependencies on Lua's string or base-library implementations.

### 8.4 Byte functions

Implement `len`, `sub`, `reverse`, `rep`, and `byte` with checked byte
arithmetic and C99 memory primitives through FFI.

For `lower` and `upper`, call C99 `tolower`/`toupper` only after converting
each byte to `unsigned char`; the result follows the process C locale just as
Lua 5.5 does. They are not Unicode case transforms.

Allocate outputs once when the final size is knowable. Allocate/root the
destination before borrowing input pointers, then perform no allocating Lua
call while those pointers are live. Use `lua_pushlstring` for the final exact
length; never rely on NUL termination.

### 8.5 `format`

Port Lua 5.5's format-language grammar and validation into a `titan.peg`
pattern built once by the string module initializer. Support:

```text
%%  %c  %d  %i  %u  %o  %x  %X
%a  %A  %e  %E  %f  %g  %G
%p  %q  %s
```

Preserve Lua's accepted flags, width, precision, length-modifier insertion,
invalid-format diagnostics, `%q` literal rules, embedded-NUL checks, and
argument counting.

Matching a format string produces a local `FormatPlan`: a dense Array of
exact `(value) -> string` `FormatPartial` closures plus one final literal
trailer. The PEG grammar collapses `%%` into literal runs and captures the
literal prefix, conversion form, exact factory, and specification-size bound
for each conversion. Ordered fallback alternatives construct error partials
for invalid specifications, invalid conversions, modified `%q`, and overlong
forms instead of rejecting the complete parse. `format` can therefore check
the corresponding argument before executing that partial and preserve
conversion-slot error order.

Titan cannot forward its `...` run directly to a C variadic call. Each exact
partial instead:

1. receives the corresponding `value` and applies Lua 5.5's exact
   `luaL_checkinteger`, `luaL_checknumber`, `luaL_checklstring`,
   `lua_topointer`, or tostring rule for that conversion;
2. calls `snprintf` with one statically explicit C variadic argument of that
   known type;
3. returns its captured literal prefix plus the exact rendered bytes.

`format` appends those returned chunks in argument order, appends the plan's
final trailer, and lets the checked builder allocate once and concatenate the
complete result in an allocation-free copy window.

Use two-pass `snprintf` sizing when required. `%s` first uses the shared
`luaL_tolstring` helper; `%p` obtains Lua's pointer identity through
`lua_topointer`; `%q` is implemented in Titan from Lua 5.5's rules.

### 8.6 `pack`, `packsize`, and `unpack`

Port Lua 5.5's binary-format parser and semantics:

```text
<  >  =  ![n]
b B h H l L j J T
i[n] I[n]
f n d
c[n] s[n] z
x X<next-option>
space
```

Preserve:

- native/little/big endian selection;
- maximum-alignment policy and power-of-two validation;
- signed and unsigned overflow checks;
- native C widths from the exact target compiler;
- zero/sign extension;
- fixed, length-prefixed, and NUL-terminated strings;
- padding and `X` alignment;
- variable-length rejection in `packsize`;
- negative/clamped initial unpack positions;
- `unpack`'s final one-based next position.

For dynamic `pack` operands, apply Lua 5.5's C checks option by option:
integer formats use `luaL_checkinteger`, floating formats use
`luaL_checknumber`, and `c[n]`/`s[n]`/`z` use `luaL_checklstring`, including
numeric-to-string acceptance. Save and restore the exact stack top around
each conversion, including its error path.

The code remains Titan plus C99 FFI. Use `sizeof`, `alignof` where appropriate,
checked pointer arithmetic, `memcpy`, and explicit endian reversal. Do not add
a C shim or call Lua's `string.pack` family.

## 9. Regex specification

### 9.1 Public types and API

```titan
record Span
  first: integer
  last: integer
end

local record GroupSpan
  local span: Span?
end

record RegexMatch
  local subject: string
  local matched_span: Span
  local groups: {GroupSpan}
end

record Regex
  local expression: string
  local capture_count: integer
  local pattern: peg.Pattern
end

local record RegexDiagnostic
  label: string
  message: string
  source: string
  position: integer
  line: integer
  column: integer
  source_line: string
end
```

`Span.last` is inclusive. An empty match or group has
`last == first - 1`. The local `groups` array has exactly `capture_count` dense
wrapper slots; each slot atomically holds either one span or nil. An unmatched
group has nil span, a matched group has one span, and a repeated group retains
the final iteration's span. This avoids relying on trailing nil Array elements,
which do not contribute to Titan Array length, and prevents callers from
mutating cached regex metadata.

Expose a compiled API:

```titan
function compile_regex(expression: string): Regex
function Regex:source(): string
function Regex:group_count(): integer
function RegexMatch:span(): Span
function RegexMatch:group_count(): integer
function RegexMatch:group_span(index: integer): Span?
function RegexMatch:whole(): string
function RegexMatch:group(index: integer): string?
function RegexMatch:values(): (string?, ...: string?)
function Regex:match(subject: string,
                     init: integer?): RegexMatch?
function Regex:gmatch(subject: string,
                      init: integer?): () -> RegexMatch?
function Regex:gsub(subject: string,
                    replacement: (string) -> string,
                    maximum: integer?): (string, integer)
```

and source-expression conveniences:

```titan
function match(subject: string,
               expression: string,
               init: integer?): RegexMatch?
function gmatch(subject: string,
                expression: string,
                init: integer?): () -> RegexMatch?
function gsub(subject: string,
              expression: string,
              replacement: (string) -> string,
              maximum: integer?): (string, integer)
```

Top-level functions compile through a private weak-value expression cache.
Compiled methods avoid repeated parsing.

Nil/omitted `init` means 1, and nil/omitted `maximum` selects the default
substitution bound described below.

Result shape is deliberately typed rather than Lua-shaped:

- compiled and source-expression `match` return `RegexMatch?`;
- callers explicitly use `whole`, `group`, `span`, or `values` to select the
  desired projection;
- each `gmatch` iteration returns one non-nil typed `RegexMatch`; its
  `whole`, `group`, and `values` methods recover text results;
- `gsub` returns transformed string and match count.

Each match roots the exact subject it indexes. The span accessors return fresh
`Span` records, not references that can mutate the match's local state.
`RegexMatch:group_count()` always equals `Regex:group_count()` for the regex
that produced it. `group` and `group_span` require an index in
`1..group_count` and raise an argument error outside it; an in-range unmatched
group returns nil. `values()` returns the whole match when there are no groups,
otherwise one value per group while preserving unmatched nil slots.

The `gmatch` record result is the deliberate typed departure from Lua's
capture tuple. Regex alternation can leave group 1 unmatched; returning that
nil as Titan's first iterator result would terminate generic `for` before
later matched groups were visible. A `RegexMatch` is always non-nil for a real
match and preserves every numbered group without abusing the loop-control
slot.

Initial positions use Lua `string.find` normalization, deliberately not raw
LPeg normalization:

| Supplied `init` | Search start |
| --- | --- |
| nil | byte 1 |
| `0` or negative overshoot | byte 1 |
| positive `1..#subject+1` | that position |
| negative within range | `#subject + init + 1` |
| positive `>#subject+1` | immediate no-match |

`^` anchors at this normalized search start, not necessarily absolute byte 1;
`$` always tests the absolute end. Position `#subject+1` can therefore match
an empty expression. Compiled and source conveniences share this table.

### 9.2 Grammar

The parser recognizes this byte grammar:

```text
regex        ::= "^"? alternation "$"? EOF
alternation  ::= concatenation ("|" concatenation)*
concatenation ::= piece*
piece        ::= atom quantifier?
quantifier   ::= "*" | "+" | "?"
               | "{" decimal "}"
               | "{" decimal "," "}"
               | "{" decimal "," decimal "}"
atom         ::= "."
               | literal
               | escape
               | character-class
               | "(" alternation ")"
               | "(?:" alternation ")"
               | backreference
```

Supported semantics:

- literal bytes;
- `.` matches any byte except LF (it does match CR);
- classes, ranges, leading-`^` class negation;
- left-biased alternation;
- capturing and noncapturing groups;
- greedy, continuation-aware `*`, `+`, `?`, `{n}`, `{n,}`, `{n,m}`;
- whole-expression `^` and `$`;
- ASCII `\w`, `\W`, `\d`, `\D`, `\s`, `\S`;
- `\s` is space, tab, vertical tab, LF, and CR, deliberately excluding form
  feed to preserve pinned `pegex` behavior;
- `\t`, `\n`, `\r`, `\f`, `\e`, and `\a`;
- word boundaries `\<` and `\>`;
- single-digit backreferences `\1` through `\9`.

`\w` is `[A-Za-z0-9_]`; the upstream README's omission of digits is stale.

Unanchored search tries the leftmost byte position. Alternatives are ordered:
`a|ab` on `"ab"` matches `"a"`. Repetition is greedy but its continuation can
make it shorten to allow the suffix. Repeated captures retain the final
iteration.

To preserve pinned tested behavior, outer anchors bind the complete
alternation: `^a|b$` anchors both alternatives. Anchors elsewhere are syntax
errors rather than ordinary literals.

Empty expressions, alternatives, and groups remain valid exactly where the
pinned parser accepts them: `""`, `"|"`, `"()"`, `"(?:)"`, `"a|"`, and
`"|a"` all compile. Diagnostic throws must therefore be placed after an
unambiguous malformed prefix, not at every temporarily empty concatenation.

### 9.3 Class and escape rules

Make malformed constructs unambiguous:

- `[]` and `[^]` are errors;
- an unclosed class is always an error;
- `]` is literal only when escaped as `\]`;
- `-` is literal when first/last in a class or escaped as `\-`; otherwise it
  forms a complete ordered range;
- a reversed range is an error;
- `^` negates only immediately after `[`;
- outside a class, regex metacharacters
  `()[]{}\\?*+|.^$` may be escaped to become literal;
- an unknown escape is an `unsupported_escape` error;
- `\v`, hexadecimal/octal escapes, `\b`, and multi-digit backreferences remain
  unsupported.

`\10` is diagnosed as an unsupported multi-digit backreference, not parsed as
`\1` followed by literal `0`.

An unescaped `{` after an atom begins a counted quantifier. A malformed count
is an error, not literal text. Literal braces must be escaped.

### 9.4 Quantifiers, captures, and backreferences

- Parse decimal bounds with checked integer arithmetic.
- Reject `max < min`.
- Reject a quantifier with no preceding atom or a second quantifier on the same
  atom.
- Detect a nullable atom under `*`, `+`, or an unbounded count and raise
  `nullable_repetition` before LPegLabel reports an internal grammar loop.
- Count the translated LPegLabel tree before constructing it and reject a
  projected tree larger than the pinned engine's
  Titan policy limit `MAXPATTSIZE == SHRT_MAX - 10`, including
  continuation/capture wrapper nodes. Return labeled `pattern_too_large`
  before expanding the count or relying on allocator/native assertion
  failure. Preserve source byte offsets on every regex AST node so this and
  all later semantic errors point at the responsible construct.
- Number groups once, in left-to-right opening-parenthesis order, in the parse
  AST. Converting or duplicating a repeated atom must never increment the
  count.
- A backreference may refer only to a previously closed group `1` through `9`.
  Validate it during compilation.
- The continuation-based converter must append its continuation after a
  successful backreference; `(a)\1b` cannot match only `"aa"`.
- If a syntactically valid referenced group did not participate on the chosen
  alternation path, the backreference is ordinary mismatch. Do not implement
  it as an unguarded native `Cb` that can raise “back reference not found”.
  Prefix the converted pattern with one private sentinel named capture per
  group; an actual group overwrites its sentinel on the current successful
  path, and the match-time equality callback returns false when `Cb` yields
  that sentinel. Native delayed-capture/backtracking order then restores the
  correct latest participating group without mutable side effects.
- Nullable analysis treats a reference to a possibly empty group as nullable,
  so an unbounded repetition of that reference is rejected before it can form
  a non-consuming loop.

Reject more than 200 capture groups with a labeled error.
`RegexMatch:values` can expose all 200 groups within Titan's
200-value projection contract: one fixed optional string plus at most 199
flexible optional strings.

### 9.5 Labeled diagnostics

Build a nonrecursive lexical pre-pass with `titan.peg` and place throws only
after an unambiguous character-class, escape, or group-prefix introducer.
Leave grouping, alternation, anchors, quantifier placement, and AST
construction to recursive descent so accepted group depth does not scale with
LPegLabel's mutable backtrack stack. Bound that recursion at 512 nested
capturing or noncapturing groups, preserving the complete 200-capture
contract. At minimum define stable labels for:

```text
expected_atom
expected_group_close
expected_class_close
empty_class
bad_range
bad_quantifier
bad_quantifier_bounds
nullable_repetition
dangling_escape
unsupported_escape
misplaced_anchor
misplaced_quantifier
invalid_backreference
too_many_captures
group_nesting_too_deep
pattern_too_large
trailing_input
```

As with PEG-expression diagnostics, this local record is formatted before
raising because Titan records do not support a custom `__tostring`. The public
error is:

```text
invalid regular expression [bad_quantifier_bounds] at L1:C6 (byte 6): maximum repeat is smaller than minimum
a{5,2}
     ^
```

The bracketed label, byte position, line, column, message, source line, and
caret are the stable test/API contract. Parser failures, semantic validation
failures, and native LPegLabel construction errors are all translated to this
public string error. Regex compilation cannot leak a raw LPegLabel error,
including a depth-dependent pre-pass backtrack-stack overflow. A referenced
group which did not participate during matching remains ordinary mismatch
rather than leaking an internal missing-back-capture error.

### 9.6 Empty-match progress

`gmatch` and `gsub` must not loop at one byte position:

- track the end-after position of the previous accepted match;
- suppress an empty candidate when its position equals that previous end,
  including the tempting trailing empty match immediately after a nonempty
  match;
- after suppressing before end-of-subject, advance the next search by one byte
  and preserve that byte in `gsub` output;
- accept an empty candidate at a different position, record its end, and let
  the next attempt suppress/recover progress as above;
- an empty candidate at end-of-subject is accepted only when its position
  differs from the previous accepted end, and iteration terminates afterward;
- an anchored expression is attempted only at its anchored position.

This is Lua 5.5's “not another empty match at the previous match end” rule,
not merely “advance after every empty match.” With a replacement callback
that returns `"X"`:

| Subject for `a*` | `gmatch` values | `gsub` result/count |
| --- | --- | --- |
| `"a"` | `"a"` | `"X"`, 1 |
| `"ba"` | `""`, `"a"` | `"XbX"`, 2 |
| `"ab"` | `"a"`, `""` | `"XbX"`, 2 |
| `""` | `""` | `"X"`, 1 |

### 9.7 `gsub` replacement contract

Regex `gsub` accepts exactly one replacement of type `(string) -> string`.
Call it once per accepted match with the whole matched string as its sole
argument. Captures do not change callback arity or values, including when a
syntactically present group did not participate. Capture projection remains
explicit through `RegexMatch` returned by `match` and `gmatch`.

The callback's exact string result replaces the match. Returning its supplied
argument retains the original text, while returning `""` deletes it. Percent
bytes in the result are literal: regex `gsub` has no replacement-template
language. A callback error propagates through the ordinary Titan callable
path, and a Lua callback returning nil, false, a number, or another non-string
observes the ordinary typed-result error.

An accepted zero-width match invokes the callback with `""`; a candidate
suppressed by the previous-end rule does not invoke it. The substitution count
counts accepted occurrences even when the callback returns the original text.

`maximum == nil` means at most `#subject + 1` substitutions, permitting the
end-of-string empty match. A nonpositive maximum performs none.

## 10. Lifetime, GC, and error containment

The implementation must make these boundaries explicit:

- The private engine table, cached native constructor/metamethod callables,
  locale patterns, relabel parser, regex parser, and weak cache tables are
  rooted in their owning module userdata once per Lua state.
- Every `Pattern.raw` is a traced `value`. Native LPeg pattern uservalue tables
  continue to root constant captures, grammar tables, relabel replacement
  tables, and PEG callbacks.
- `Regex` holds its compiled `peg.Pattern` in a local traced field. Regex
  iterators root the subject, regex, and current position for their complete
  lifetime. A synchronous regex `gsub` frame roots the subject, regex,
  replacement function, whole-match argument, and returned string across each
  callback.
- Callback calls may allocate, trigger full/generational GC, or raise. The
  Titan wrapper retains only rooted objects and byte offsets across them, then
  rederives subject/result pointers afterward. LPegLabel's own VM may retain
  instruction, capture, and subject pointers across a callback; that is safe
  only because the vendored engine roots its immutable, nonmoving Lua strings
  and pattern userdata according to its native protocol.
- Lua-stack helpers save and restore the exact top. Where a Lua C API call can
  raise, use Titan's existing error/defer model so temporary roots do not leave
  stale stack entries on a caught error. Regex `gsub` itself uses the ordinary
  generated typed-call/result path, not a manual `lua_pcallk` replacement
  wrapper.
- Match-time/runtime captures, function captures, relabel replacement
  functions/lookup metamethods, typed regex replacement callbacks, and
  `__tostring` run through their documented non-yieldable boundaries. A yield
  attempt raises the ordinary Lua boundary error, and caught dynamic
  callback/metamethod errors restore the exact pre-call stack top before
  propagating.
- Capture and replacement callbacks run serially on the current Lua thread.
  No process-global mutable pattern state is added.
- `set_max_stack` is per private engine/per Lua state. Regex compilation does
  not silently mutate it.
- C allocation, integer, format, and pointer failures become ordinary Titan/Lua
  errors with stable context. No C longjmp crosses an unrelated native frame.

## 11. Build, install, and publication changes

### 11.1 Make graph

Extend `Makefile` with:

- pinned LPegLabel variables, source/header lists, build directory, object
  list, archive, configuration stamp, and exact membership validation;
- LPegLabel in both `STDLIB_NATIVE_PREREQS` branches and in
  `rock-post-install`/`stdlib` transitively;
- the private archive between `titanlib.o` and bundled libuv in
  `STDLIB_EXTRA_OBJECTS`;
- all `titan/peg/*.titan` and `titan/string/*.titan` sources;
- `peg` and `string` in roots/modules/shims;
- vendor include flags in standard-module compilation only;
- LPegLabel source/config/archive identity in the stdlib completion stamp;
- exact clean rules for generated folder-main C/object files, private native
  build outputs, and the two generated shims;
- license installation for LPegLabel, LPeg, ta-regex, and translated Lua 5.5
  `lstrlib.c` material.

Every warm `make stdlib` must rescan `titan.a` for exactly nine keys without
changing pair mtimes. Missing or changed vendored sources, headers,
configuration, or private-archive prerequisites rebuild the native archive and
provider; private archive construction proves its exact five-member manifest.
The ordinary warm metadata rescan proves the nine logical keys, while
dynamic/static production smokes prove that the metadata-free LPegLabel
payload remains usable. Do not invent a synthetic Titan metadata marker for
that payload.

Keep the private archive out of `runtime`, `titan`, `install-titan-sdk`, and
bootstrap targets. Those targets deliberately finish the native runtime/SDK
before LuaRocks deploys the compiler; LPegLabel is standard-library payload
built only for `stdlib` or the later post-install phase.

### 11.2 Source rock

Keep the active rockspec source-only and retain:

```lua
"lpeglabel >= 1.5.0"
```

That dependency is compiler-owned. Ensure the packed source-rock inventory
contains the tracked vendor snapshot and all new Titan sources, and add a
pack/unpack inventory test rather than proving only a checkout-local
`luarocks make`. The post-install hook invokes the installed compiler once
with all nine roots and an `-X` payload beginning:

```text
titanlib.o, private LPegLabel archive, [bundled libuv archive]
```

The installed SDK must not contain the private archive or headers. The
Lua publisher transaction owns only the canonical provider pair, dSYM, shims,
and stale native layouts. The surrounding Make/source-install target copies
notices and licenses nontransactionally before invoking it; those files remain
outside the rock manifest and publisher rollback.

### 11.3 Publisher and prototype upgrade policy

Extend `scripts/stdlib_installer.lua`'s authoritative module list to nine and
validate:

- all ten required Lua entry points resolve (bare support plus nine logical
  entries);
- all nine logical DSO protocols;
- exactly nine archive metadata keys;
- DSO/archive ABI/types equality;
- a fresh-process archive-backed validation image;
- nine generated shims.

Do not redesign the publisher's existing generic destination/predecessor
rules. Make only the mechanical current-layout changes required for the two
new modules. In particular, do not add an exact seven-module classifier,
shim-retirement migration, conflicting-file decision tree, or cross-ABI
compatibility matrix. Titan is still a prototype: if a stale layout conflicts,
and always when a future change bumps the ABI, the supported remedy is to
remove the old installation and build a fresh versioned tree.

Preserve commit order:

```text
new/changed shims and dSYM -> titan.a -> titan.so last
```

For a caught archive/DSO failpoint while replacing a current nine-module
layout, retain the existing exact rollback guarantee. Clean installation,
ordinary same-layout reinstall, and current-layout rollback are the acceptance
targets; old prototype layouts and cross-ABI upgrades are not.

### 11.4 Licenses and notices

Add and install:

```text
LICENSES/lpeglabel-LICENSE
LICENSES/lpeg-LICENSE
LICENSES/ta-regex-LICENSE
LICENSES/lua-LICENSE
```

Update `THIRD_PARTY_NOTICES.md` with:

- exact LPegLabel tag/commit and static incorporation;
- LPeg-derived C attribution;
- relabel derivative attribution;
- exact ta-regex commit and Titan translation attribution;
- the continuation-based PUC-Rio algorithm citation;
- Lua 5.5 `lstrlib.c` attribution and MIT terms for the translated
  format/pack parsers and semantics;
- the existing libuv notice unchanged.

Retain source copyright headers in translated files and identify the upstream
source revision at the top of each derivative.

## 12. File-by-file implementation map

### New production files

- `vendor/lpeglabel/**`: pinned native snapshot, private namespace patch,
  opener header, manifest, notices, and the four test-only upstream Lua
  fixtures; the source rock carries them but installation does not.
- `titan/peg/**`: opaque wrapper, engine initialization, constructors,
  combinators, captures, relabel parser/compiler/conveniences.
- `titan/string/**`: byte operations, formatting, packing, regex
  parser/compiler/API.
- `LICENSES/{lpeglabel-LICENSE,lpeg-LICENSE,ta-regex-LICENSE,lua-LICENSE}`.
- `doc/language/standard-library-peg.md`.
- `doc/language/standard-library-string.md`.
- `doc/implementation/lpeglabel-embedding.md`.
- `doc/implementation/string-library.md`.

### Existing production/configuration files

- `Makefile`: native archive, nine roots/shims, flags/stamps, publication,
  licenses, exact cleanup.
- `.gitignore`: exact private build paths, generated folder-main C/object
  paths, and `titan/{peg,string}.lua`; no broad globs.
- `titan-compiler/{ast,lexer,parser,syntax_errors}.lua`: short import aliases
  plus the `ExpIs` syntax and diagnostics.
- `titan-compiler/{checker,coder}.lua`: reuse the exact written-cast relation
  for nonraising, single-evaluation `is` predicates; do not alter
  `types.compatible` or widen `as`.
- `scripts/stdlib_installer.lua`: nine-module validation using the existing
  publication/rollback model; no historical migration layer.
- the active rockspec: source-package/comment/license coverage while
  retaining compiler dependency.
- `THIRD_PARTY_NOTICES.md`.
- `AGENTS.md`: current prerequisite/provider/root/shim/key/import instructions
  must describe the nine-module result.
- `README.md`: public module/API overview, build self-containment, nine-root
  provider wording, and roadmap removal.

### Existing docs

- `doc/language/index.md`: link both new language chapters and list the two
  standard modules.
- `doc/language/{expressions,grammar,types}.md`: specify `exp is T`, its
  precedence, exact relationship to written `as`, total function/value cases,
  and absence of narrowing.
- `doc/implementation/index.md`: link both new implementation chapters.
- `doc/implementation/{ast-typedecl,lexer-parser,checker,codegen-constructs}.md`:
  document `ExpIs`, shared cast admissibility, and predicate code generation.
- `doc/language/modules.md`, `lua-interop.md`, and
  `multi-module-libraries.md`: aliases, qualified Lua names, nine shims/keys.
- `doc/implementation/driver.md`, `folder-modules.md`,
  `multi-module-libraries.md`, and `lua-interop-internals.md`: nine-root build,
  two new folder modules, private payload, loader/state behavior.
- `doc/implementation/ffi-lua-api-followup.md`: classify these calls as
  trusted standard-library-internal raw Lua C API usage and specify exact
  stack effects, roots, non-yieldability, protected error/defer discipline,
  and the prohibition on borrowed wrapper pointers across callbacks.
- Update other exact “seven” lists found by repository search only where they
  describe the current standard-library provider; do not rewrite historical
  worklogs as if they had originally covered nine modules.

### Tests and CI support

- `spec/parser_spec.lua`: short import desugaring and qualified-name
  noncollision, plus `is` precedence, target parsing, and diagnostics.
- `spec/checker/type_tests_spec.lua`: exact parity with the written-cast
  relation and no narrowing.
- `spec/coder/type_tests_spec.lua`: single evaluation, false-on-mismatch,
  total casts, exact integer/range checks, option and C boundaries, record/Array
  identity, and deferred function callability.
- `spec/stdlib/peg_spec.lua`: core binding.
- `spec/stdlib/peg_relabel_spec.lua`: translated relabel.
- `spec/stdlib/string_spec.lua`: non-regex functions.
- `spec/stdlib/string_regex_spec.lua`: regex and Lua-facing APIs.
- `spec/lpeglabel_build_spec.lua`: vendored native archive, namespace,
  configuration stamps, tool wrappers, invalidation, and exact cleanup.
- `spec/fixtures/stdlib/native/lpeglabel_private_harness.c`: test-only host for
  the complete pinned upstream suites; never a production string/PEG shim.
- `spec/libuv_build_spec.lua`: nine-root Make graph and both libuv-mode
  `STDLIB_EXTRA_OBJECTS` payloads.
- `spec/rockspec_spec.lua`: source install, notices, isolation, nine artifacts.
- `spec/stdlib_installer_spec.lua`: clean/current nine-module publication and
  existing failpoint rollback.
- `spec/fixtures/stdlib/titan_stdlib_types.lua`: preserve the historical seven
  interface snapshots byte-for-byte. Split the build spec's current root set
  into all-nine and legacy-seven lists so its existing ABI-compatibility loop
  continues to use this fixture. Add separate exact peg/string interface
  snapshots only if they provide useful new stability coverage.
- `spec/support/async_stdlib.lua`: canonical nine-shim production layout.
- `spec/support/ci_test_groups.sh`: explicit non-LuaCov peg/string cohort.
  Classify `lpeglabel_build_spec.lua` with the serial native/package gates.
- `spec/support/ci_stdlib_snapshot.sh`: save/restore both new shims.
- `spec/support/ci_libuv_mode_smoke.sh`: dynamic/static peg/string smoke and
  dependency isolation in both libuv modes.
- `spec/support/ci_abi_migration_smoke.sh`: update its current exact known-shim
  list where required by the existing CI flow; add no peg/string-specific
  historical migration cases.
- `.github/workflows/ci.yml`: nine artifact assertions, regular library cohort,
  and focused sanitizer gate.

## 13. Test specification

### 13.1 Core PEG behavior

First add a test-only private-opener harness that runs the complete pinned
`test.lua`, `testlabel.lua`, and `testrelabelparser.lua` against the namespaced
vendored C engine. A purpose-built native test host links the private archive,
registers only that process's `package.preload["lpeglabel"]` as a forwarding
call to `titan_lpeglabel_open`, points `package.path` at the pinned test-only
`relabel.lua`, and runs each suite in a fresh process. It is never linked into
the provider or installed. This proves the symbol/registry patch itself,
independently of the Titan wrapper. Then cover the public binding:

- every constructor and explicit coercion replacement;
- zero/one/many `sequence`, `choice`, and `difference` folds, proving left
  association;
- ordered choice commitment, predicates, repetition, look-behind, and
  `at_most(p, 0) == succeed()`;
- checked pattern-size projection for extreme `any` and repetition counts;
- exact native-facing bounds: `Carg` 0/1/32767/32768, `select_capture`
  0/32767/32768 plus integral/fractional floats, look-behind 255/256, grammar
  1000/1001, stack maximum and maximum-plus-one, and UTF range
  endpoints/surrogates;
- grammars, recursion, tagged string/integer recovery names, duplicate names,
  and dense rules supplied from both a Titan Map and an ordinary Lua table;
- `"1"`/`"01"`/`1`/`0` label identity and exact string-versus-integer
  recovery, proving the documented native divergence;
- ordinary farthest failure and thrown label positions from positive,
  negative, non-one, zero, oversized-positive, and negative-overshoot initial
  positions;
- every delayed-capture rule in section 6.4, heterogeneous/nil captures,
  the complete no-nested-capture matrix, missing/present extra match
  arguments, capture timing, callback errors, and exact stack restoration;
- exact callback arity with Lua `select('#', ...)`: runtime's third empty
  string, match-time/function-capture implicit whole-match value, fold's
  required accumulator and possibly empty variadic tail, and flexible callback
  result counts;
- deferred callback callability: plain Lua and C functions plus callable
  tables/userdata use the generic path, while constructing a pattern with a
  genuinely noncallable function-typed value succeeds and raises only if the
  matching path actually invokes it; an abandoned alternative or otherwise
  uninvoked callback must not raise;
- default and changed stack limit;
- binary subjects and embedded NUL;
- 200-value boundary errors;
- Lua calls into Titan patterns and Titan callbacks into Lua;
- non-yieldability of runtime/match-time/function-capture callbacks.

Run patterns and callbacks through repeated full and generational GC windows,
including after their construction locals have gone out of scope.

The compiler-focused `is` suites separately prove that PEG's use of the
operator rests on the language contract rather than a library-only raw tag
shortcut: parser precedence/diagnostics, the exact written-`as` admissibility
relation, once-only evaluation, false-on-mismatch checks, total-cast truth,
absence of narrowing, and always-true `value is <function type>` with failure
deferred to invocation.

### 13.2 Relabel

Port every pinned expression-language behavior case and every
`testrelabelparser.lua` diagnostic snapshot:

- expression and multi-rule grammars;
- source and already-compiled pattern inputs to `compile`, `match`, and
  `gsub`;
- definitions of patterns, functions, tables, strings, and numbers;
  nil/false rejection; duplicate/invalid names; dense definitions from Titan
  Maps and ordinary Lua tables;
- all capture/replacement suffixes, including anonymous `{: p :}`;
- ordered replacement dispatch: string before exact Lua integer before Map
  before unconditional function fallback, including an integral float that is
  not an integer selector, a callable Map that remains a query, callable
  non-Map values, deferred failure for an invoked noncallable fallback, and no
  failure when that fallback is never invoked;
- dynamic callback-suffix adapters with the same deferred callability
  behavior;
- comments, whitespace, locale classes, `%w == locale alnum`, and update
  invalidation;
- `%{identifier}`, `%{decimal}`, identifier-only/no-space `p^label`, decimal
  repetition after `^`, and recovery;
- weak cache reuse followed by collection;
- leftmost `match` records, normalized starts, empty inclusive ranges,
  preserved zero/one/many/nil capture runs, labeled-failure commitment, and
  relabel `gsub`;
- a 200-capture module match proving the record path does not consume public
  capture capacity;
- exact labeled position/line/column/source/caret messages at EOF,
  CRLF, and multiline errors, with an explicit snapshot for Titan's corrected
  `line_column` divergence.

The relabel translation must compile its own parser using the new public
binding; tests should fail if it reaches a private raw-native escape hatch.

### 13.3 Non-regex string parity

Use the exact local Lua 5.5 library as a differential oracle in tests, not as
the production implementation:

- empty, ASCII, high-bit, embedded-NUL, and long strings;
- all positive/zero/negative/extreme index cases;
- `rep` with empty/nonempty separator, zero/negative count, overflow;
- locale-controlled lower/upper cases with `LC_ALL=C` for deterministic CI;
- `byte`/`char` arity, ranges, NUL, and 200-value bound;
- `tostring` with omitted, one, and side-effectful surplus arguments, proving
  ordinary Titan nil-padding plus left-to-right evaluation and value discard;
- typed-boundary rejection of numeric subjects, fractional/out-of-range
  numbers in fixed integer slots, and numeric strings in fixed numeric slots,
  plus acceptance of representable integral floats;
- every valid/invalid `format` conversion, flags, width, precision, `%q`,
  `%p`, embedded NUL, missing/surplus values, `__tostring`, and raised
  metamethod, including dynamic integral-float and number-as-string cases;
- every pack format family, endian/alignment combinations, signed/unsigned
  boundaries, variable strings, Lua C numeric/string coercions, padding, short
  input, invalid format, and round trips;
- non-yieldability and exact stack-top restoration when a conversion,
  `__tostring`, or protected helper raises;
- differential format/pack corpora generated deterministically from a bounded
  matrix rather than an unseeded fuzz test;
- sanitized Lua paths proving production functions do not call Lua's string
  library.

### 13.4 Regex

Port all 89 upstream assertions, then add:

- each documented token and unsupported feature;
- left bias, continuation-aware greediness, whole-pattern anchors, and `^`
  under nil/one/non-one/zero/negative/out-of-range initial positions;
- valid empty expression/alternative/group forms;
- nested/repeated/unmatched captures and exact span/substrings, including
  `RegexMatch` accessors, immutable copied spans,
  `match:group_count() == regex:group_count()`, and dense hidden group state;
- all confirmed upstream defects;
- malformed classes, escapes, groups, anchors, quantifiers, bounds, nullable
  repetition (including nullable backreferences), oversized pattern,
  unmatched-branch backreference ordinary failure, continuation after a
  backreference, `\10` rejection, and nonexistent/forward backreferences;
- `{0}`, `{n}`, `{n,}`, and `{n,m}` around capturing groups without changing
  syntactic group count;
- literal/escaped brace boundary, NUL/high-bit literals/classes/dot, exact
  `\s` membership (vertical tab yes, form feed no), and locale invariance;
- exact labeled regex diagnostics at beginning, middle, EOF, and
  multiline/CRLF input;
- literal `find` differential checks over metacharacters, empty needles,
  extreme initial positions, NUL/high bytes, and exact fixed-pair result
  values;
- typed compiled/source `match` records and `values` preserving trailing nil
  capture slots;
- exact 512-deep noncapturing-group success with labeled 513-depth rejection,
  including independence from `peg.set_max_stack`;
- 200 nested-capture success plus labeled 201-capture rejection;
- generic-for over a match whose group 1 is unmatched, proving the non-nil
  `RegexMatch` iterator control value;
- empty-match progress at start, between bytes, and end, with exact `gmatch`
  and callback-only `gsub` parity for `a*` over `"a"`, `"ba"`, `"ab"`, and
  `""`, including the exact whole-match callback arguments;
- regex `gsub` with captures and unmatched captures still passing exactly one
  whole-match string; explicit retain/delete results; literal `%` result
  bytes; maximum count; compiled/cached parity; rejection of nonfunction
  replacements and non-string callback results; callback error propagation,
  recovery, and GC during replacement;
- non-yieldability and exact stack restoration after capture, lookup,
  relabel replacement, regex replacement-callback, and iterator errors;
- cached and compiled APIs returning identical results;
- callback/iterator/regex survival under full and generational GC.

### 13.5 Packaging and production images

Extend existing serial/package tests to prove:

- exact vendored source/header/config invalidation and warm no-op mtimes;
- both bundled/system `-X` payloads include private LPegLabel in the right
  position;
- exactly nine roots, keys, protocols, and shims;
- Titan installs no additional/private LPegLabel archive, header, or raw Lua
  module; the compiler-owned external `lpeglabel.so`/`relabel.lua` may still
  exist elsewhere in the prefix;
- direct `require "titan.peg"`/`require "titan.string"` from the canonical DSO;
- bare Lua `require "string"` is unchanged;
- a static standalone using regex still runs after the DSO, shims, and external
  LPegLabel/relabel search paths are unavailable;
- clean/current nine-module publication and both archive/DSO failpoint
  rollbacks;
- exact snapshot/restore of the new shims;
- no LPegLabel dynamic dependency and no public/raw symbols.

### 13.6 CI classification

Keep all PEG, relabel, string, and regex behavior outside LuaCov. LuaCov
measures the Lua compiler, not generated Titan/native library behavior.

Add an explicit `library-peg-string` cohort. On regular Linux, run it on the
producer after `library-net-os` and before `compiler-core` initially, using a
small number of compiled fixtures with many assertions. Measure the resulting
one-core job before locking placement: retain it there only with safe margin
below 15 minutes; otherwise put the explicit cohort on the consumer before its
compiler-heavy shard. Preserve the current pack-before-tests/mode-smoke
artifact ordering either way. The complete `libraries` command runs serial
tests first, then uv/fs, net/OS, and peg/string workers in parallel and reports
each status separately.

Build vendored LPegLabel with sanitizer flags in the existing sanitizer job.
Add one focused PEG/regex native gate covering:

- pattern/callback/constant rooting through full and generational GC;
- malformed input and backreference continuation;
- dynamic and static production calls.

Do not repeat the full pure string/regex behavior matrix under sanitizers.

## 14. Implementation phases

### Phase 0 — lock the public contract

1. Resolve the review-default table.
2. Freeze public names/signatures, regex grammar, error format fields, and
   the absence of `dump`.
3. Add doc skeletons so implementation reviews have a single normative API.

Exit: maintainer accepts the specification or records edits in this file.

### Phase 1 — vendor and build the private engine

1. Import the exact pinned LPegLabel files and notices.
2. Apply the complete symbol/registry namespace patch.
3. Add reproducible archive rules, stamps, deterministic membership scan,
   clean behavior, sanitizer flags, and Make-level specs.
4. Prove Lua 5.5 compatibility and symbol isolation before using it from
   Titan.

Exit: private five-member archive builds/no-ops/rebuilds correctly on Linux;
namespace tests pass; no runtime archive or SDK install changes.

### Phase 2 — add nonraising type tests

1. Add the `is` keyword and `ExpIs` parser/AST form at the same precedence and
   non-chaining level as written `as`.
2. Share the written-cast admissibility helper in the checker without widening
   it or changing `types.compatible`; produce `boolean` and add no narrowing.
3. Generate once-only predicates that mirror every potentially failing cast,
   and constant true for admitted total casts, including
   `value is <function type>`.
4. Update both manuals and add focused parser, checker, and coder suites.

Exit: every admitted `exp is T` returns whether the corresponding written
`exp as T` would succeed, without raising for a mismatch, evaluating `exp`
twice, or changing branch types.

### Phase 3 — implement `titan.peg`

1. Add folder module, private opener import, module initializer, and rooted
   engine/metamethod cache.
2. Implement opaque patterns, constructors, grammar conversion, folds,
   checked construction sizes, predicates, repetitions, tagged labels,
   delayed captures, exact native callback adapters with deferred Titan
   callability, absolute failure correction, locale, stack limit, and version;
   remove `_raw_type` and every eager raw-function check.
3. Add short import and parser test.
4. Add core behavior, Lua interop, coexistence, and GC tests.

Exit: explicit source compilation and a temporary combined provider exercise
the complete core binding without external runtime LPegLabel.

### Phase 4 — port relabel

1. Translate the parser using public `peg` operations.
2. Add Lua-table-compatible definition wrappers, compiled-pattern inputs,
   labeled diagnostics, the shared weak compilation cache, locale invalidation,
   leftmost `Match` records, exact whole-match `gsub`, deferred callback-suffix
   adapters, and ordered dynamic expression-suffix replacement dispatch.
3. Port upstream parser/behavior tests and confirm cache collection.

Exit: relabel test corpus and diagnostic snapshots pass; `peg` still has no
dependency on `titan.string`.

### Phase 5 — make regex the first `titan.string` client

1. Add the string folder-module skeleton and binary-safe
   allocation/index/slicing helpers needed by regex.
2. Translate the `pegex` AST/parser/converter using `titan.peg`.
3. Add source-carrying AST nodes, labels, and semantic validation before
   native construction.
4. Correct backreference continuation, unmatched-path sentinel handling,
   nullable-reference analysis, and syntactic group accounting.
5. Implement `Regex`, weak compile cache, top-level matching APIs, iterator,
   exact whole-match replacement callbacks, and empty-match progress.
6. Port upstream assertions and add the complete defect/diagnostic matrix.

Exit: regex is the first production client of `titan.peg`;
documented/tested pinned behavior is preserved, every confirmed defect has a
regression, and no raw LPegLabel error escapes.

### Phase 6 — complete the non-regex `titan.string` surface

1. Implement byte operations, case transforms, repeat, and `tostring`.
2. Port the format language into one initializer-built PEG that produces
   exact `FormatPlan`/`FormatPartial` closures, using `is` for `%q`'s dynamic
   cast-success dispatch so `raw_value_type` is unnecessary; port the pack
   language, and use C99 FFI with exact per-slot Lua C conversions and explicit
   typed C variadic calls.
3. Add Lua 5.5 differential and GC/error tests.
4. Audit existing standard-library byte/string helpers. Use
   `titan.string.find` and `titan.string.sub` in both `titan.net` and
   `titan.os`; keep the delayed-DNS test honest by building the exact complete
   `peg -> string -> net` dependency closure. Remove the transient public UV
   byte helpers that no production facade needs.

Exit: every agreed non-regex function matches the local Lua 5.5 oracle over
the documented typed input domain and within Titan's 200-value boundary, and
the standard-library reuse audit preserves module ownership rather than
introducing fixture-only dependency machinery.

### Phase 7 — integrate the nine-module provider

1. Add both folder roots/sources/shims and private native archive to all Make
   paths and stamps.
2. Extend installed/source runtime builds, current-layout publisher
   validation, licenses, cleanup, snapshots, and smokes.
3. Recheck the current seven pre-existing interfaces, refreshing the exact UV
   fixture for the deliberate prototype helper retirement, and, if adopted,
   generate/review separate peg/string interface snapshots.
4. Prove bundled/system, dynamic/static, clean-search-path, and
   clean/current-layout publication behavior.

Exit: a clean isolated source-rock install publishes one valid nine-key pair,
a current nine-module reinstall works, and both failpoints restore that current
layout.

### Phase 8 — docs, CI, and release evidence

1. Finish both language chapters and both implementation chapters; link both
   manuals.
2. Update all current seven-module lists and README.
3. Add explicit non-coverage cohort and focused sanitizer gate.
4. Run full local gates, address adversarial review, push Linux, and inspect
   exact-head Codecov publication/policy results. Record the maintainer's
   manual macOS waiver; do not dispatch that workflow for this feature.

Exit: docs match shipped API; Linux and Codecov verify the exact reviewed
head, with the manual macOS waiver recorded.

## 15. Acceptance gates

Focused development gates:

```sh
busted spec/parser_spec.lua
busted spec/checker/type_tests_spec.lua
busted spec/coder/type_tests_spec.lua
busted spec/lpeglabel_build_spec.lua
busted spec/libuv_build_spec.lua
busted spec/stdlib/peg_spec.lua
busted spec/stdlib/peg_relabel_spec.lua
busted spec/stdlib/string_spec.lua
busted spec/stdlib/string_regex_spec.lua
busted spec/stdlib_installer_spec.lua
busted spec/rockspec_spec.lua
bash spec/support/ci_test_groups.sh library-peg-string
```

Integrated local gates:

```sh
make test
bash spec/support/ci_test_groups.sh libraries
luarocks make && bash spec/support/ci_test_groups.sh compiler
```

Clean isolated bundled install:

```sh
export PREFIX=/tmp/titan-peg-string-bundled
export PATH="$PREFIX/bin:$PATH"
make lua PREFIX="$PREFIX"
make luarocks PREFIX="$PREFIX"
make libuv PREFIX="$PREFIX"
"$PREFIX/bin/luarocks" make
bash spec/support/ci_libuv_mode_smoke.sh bundled
```

System-mode smoke must rebuild/publish the pair with the same tool identity and
run the focused SDK layout plus dynamic/static peg/string production cases.

Sanitizer acceptance uses the existing job flags and focused gate. Final branch
acceptance is:

- green Linux producer, consumer, and sanitizer jobs for the exact head;
- successful Codecov uploads for both compiler shards;
- no manual `workflow_dispatch` macOS run for this feature, per the
  maintainer's explicit waiver.

## 16. Requirements traceability

| Informal requirement | Planned proof |
| --- | --- |
| Add nonraising `exp is T` as the exact predicate twin of written `as` | Sections 1-3 and Phase 2; parser plus `checker/coder/type_tests_spec.lua`, with exact cast-relation, once-only, no-narrowing, and deferred-function-callability cases |
| Add lpeglabel/relabel bindings as `peg` | Sections 5-7; `peg_spec` and `peg_relabel_spec` |
| Replace operators with functions | Section 6.3 mapping table |
| `+`, `-`, `*` are variadic left folds | Exact arity/identity/association in section 6.3 and fold tests |
| Regex first client in new `string` module | Sections 8-9 and one-way dependency graph |
| Port linked `pegex.lua` | Exact commit, dialect, upstream assertions, attribution |
| Better invalid-regex errors using labels | Structured labels and diagnostic matrix in sections 9.5 and 13.4 |
| Typed regex `match`/`gmatch`/`gsub` plus literal `find` | Exact public signatures/results in sections 8.2 and 9.1 |
| Remove regex replacement raw-type dispatch | Exact whole-match `(string) -> string` callback in sections 1, 9.1, 9.7, and regex tests |
| Replace PEG/string raw cast-success probes | `is`-based relabel ordering with an exact-integer exception in sections 6-7, and PEG-built `FormatPlan` `%q` dispatch in section 8.5 |
| Rest of string library in Titan/C99, no shim | Sections 8.2-8.6; only `dump` is an explicit review exclusion |
| Add `tostring` and identify other Lua conversion use | Section 8.3: only `format %s` shares `luaL_tolstring` |
| No installed lpeglabel/relabel runtime dependency | Private archive, clean search-path, static/dynamic isolation proofs |
| Static link into standard-library DSO/archive | `STDLIB_EXTRA_OBJECTS`, nine-key provider, both mode smokes |
| Prototype ABI policy | Keep the current marker here; no migration/conflict machinery; clean install on future ABI bumps |
| Add test suite | Section 13 across behavior, defects, GC, packaging, sanitizer, macOS |
| Keep docs part of done | Two language and two implementation chapters plus index/current-provider updates |

## 17. Post-implementation API and implementation cleanup

Status: the original implementation, allocation audit, and local validation
are complete on `agent/peg-string-standard-library`. The `is`/format/gsub/PEG
follow-up is in implementation and validation; after adversarial review it
will be committed and pushed to PR #40. The maintainer explicitly waived a
manual macOS run.

This section is the durable continuation record for the maintainer's API
spot-checks and the repository-wide pattern audit they imply. Preserve all
pre-existing work while completing the authorized validation, commit, push,
PR refresh, and exact-head Linux CI follow-through.

### 17.1 Required design rules

- `exp is T` is the nonraising predicate twin of the written `exp as T` cast:
  preserve the exact cast relation, evaluate once, return a boolean, and do not
  narrow. Prefer it over raw Lua type helpers when cast success is the
  question. `value is <function type>` is always true because callability is
  deferred until invocation; retain raw subtype probes only for required tag
  identity such as relabel's exact Lua-integer branch.
- The canonical `titan/string/string.titan` and `titan/peg/peg.titan` mains own
  both the public declarations and their implementations. A contributor may
  retain module-local records, state, and helpers shared by multiple public
  implementations, but must not contain a sole-use implementation function
  whose only caller is a public declaration that merely forwards the same
  arguments and results. Inline that body in the public declaration and
  delete the dead local.
- Preserve an adapter closure when its exact callable type is valuable for a
  repeatedly executed fast path. The rule above targets obfuscating sole-use
  forwarding layers, not exact-type hot-loop adapters or genuinely shared
  helpers.
- A pure zero-parameter query whose answer is invariant for the loaded module
  on a machine must run once in the canonical main's `do ... end` initializer
  and populate module-local cached state. Do not apply this to factories,
  mutable-state initialization, locale-sensitive builders, or lazy work whose
  execution is conditional.
- `ffi.<type>.new_array(count)` already returns GC-owned dynamically sized
  storage. The owner can be passed directly to a `value` field or argument,
  queried with `#owner`, and cast to the corresponding FFI pointer. Do not add
  a record or a temporary `local storage: value = owner` merely to duplicate
  those three capabilities. Keep a record when it carries genuinely distinct
  metadata, such as a logical length different from the allocation, a borrowed
  or offset pointer, asynchronous lifetime/type erasure, or related state.
- Every maintainer spot-check of one such pattern requires a sibling/call-graph
  audit across the standard library, not just a local edit. Encode the result
  in `AGENTS.md` so future work repeats the audit automatically.

### 17.2 Changes already made

- Public `string` and `Regex` forwarding wrappers have been inlined into
  `titan/string/string.titan`; their now-unreferenced contributor helpers have
  been removed.
- Public PEG forwarding wrappers have been inlined into
  `titan/peg/peg.titan`; their now-unreferenced contributor helpers have been
  removed.
- `titan/peg/captures.titan` became empty and has been removed from the folder
  ensemble, Make/source manifests, fixture constituent lists, and this plan's
  source layout.
- The machine-invariant string limits and native format facts are cached once
  from the main module initializer: maximum string bytes, integer length
  modifier, host endianness, and native maximum alignment.

The direct allocation pass is settled and independently reviewed.

### 17.3 Completed delegated work

- `/root/ffi_string_buffers` replaced `StringBytes` and
  `allocate_string_bytes` with direct owned FFI arrays, preserving the
  distinction between allocation count and logical string length, and ran
  focused string tests.
- `/root/stdlib_antipattern_audit` performed a read-only audit of every
  `titan/**/*.titan` module for the three patterns above; it reported exact
  declarations, call counts, and whether each candidate is a real violation
  or an intentional adapter, factory, or lifetime record.
- `/root/inline_refactor_adversary` performed adversarial review after the
  shared files settled, including dead declarations, stale source lists,
  documentation claims, and focused compile/runtime failures.
- `/root/uv_owned_array_cleanup` implemented the justified UV siblings, and
  `/root/owned_array_adversary` plus `/root/uv_cleanup_adversary`
  independently checked their GC, width, pointer, and logical-length
  invariants.
- The primary agent integrated the cross-stdlib fixes, updated `AGENTS.md` and
  implementation manuals, reconciled overlapping edits, and ran the final
  validation matrix.

At that prior audit stage, no agent staged or committed any file. This is
historical context only; the maintainer has since requested publication of the
completed follow-up.

### 17.4 Current implementation and documentation work

1. Added `exp is T` across parser, checker, and coder using the existing
   written-cast relation, with both-manual and focused compiler coverage.
2. Replaced formatter and PEG raw cast-success probes with `is`; retained
   relabel's exact integer-tag probe, its Map-before-function ordering, and its
   unconditional deferred-callability fallback. Regex `gsub` now has only the
   exact whole-match callback surface, so it has no raw replacement dispatch.
3. Finished the direct-owned-array string allocation pass and inspected every
   pointer/count use for zero-length, terminator, overflow, and logical-length
   correctness.
4. Triaged the cross-stdlib audit, applied only structurally equivalent fixes,
   and documented why records or adapters with extra semantic work remain.
5. Updated `AGENTS.md` with the rules in section 17.1.
6. Corrected `doc/implementation/string-library.md` and
   `doc/implementation/lpeglabel-embedding.md`: contributor files expose only
   module-local declarations and shared implementation machinery, while the
   canonical mains contain public implementations. Removed stale references to
   thin forwarding wrappers and `captures.titan`.
7. Searched source, specs, docs, Make inputs, and plans for removed
   declarations, `_impl` names, `captures.titan`, and claims that contributor
   files own the public implementations.

### 17.5 Validation matrix

Run all commands from the repository root with one prepared isolated absolute
prefix. Keep the real Git index untouched; source-pack tests that need the
unstaged deletion of `captures.titan` must use a temporary index populated
from `HEAD` and updated only inside `/tmp`.

Required gates:

1. `make stdlib` to typecheck and link the canonical nine-module provider.
2. `bash spec/support/ci_test_groups.sh library-peg-string`.
3. Focused `spec/libuv_build_spec.lua` declaration/source-manifest cases and
   the rockspec vendored-source pack/unpack case.
4. At least one delayed-DNS `spec/stdlib/uv_late_callbacks_spec.lua` case,
   because its private source ensemble mirrors the PEG/string contributors.
5. Any focused suites covering cross-stdlib files changed after the audit.
6. `git diff --check`, an unused/dead-local search, and a final adversarial
   diff review.
7. If the cross-stdlib cleanup reaches async/UV lifetime code or otherwise
   broadens beyond mechanically equivalent declarations, run the complete
   non-coverage `libraries` group; use `make test` if compiler behavior or
   shared compiler fixtures are affected.

The final handoff must distinguish tests run after the last shared-file edit
from earlier green runs, list intentional retained adapters/records, identify
the published commit, and report exact-head Linux CI. Do not dispatch the
waived manual macOS workflow.

### 17.6 Cross-standard-library audit classification

The full `titan/**/*.titan` audit found no additional public declaration whose
body merely forwards to a sole-use private implementation, and no additional
private zero-parameter helper that recomputes a pure module/machine invariant.
The apparent no-parameter candidates outside string/PEG are factories,
dynamic runtime/task/thread queries, mutable initializers, or public foreign
endpoints. In particular, `titan.uv._version` is public rather than the private
helper pattern requested here.

The UV storage audit classifies the candidates as follows:

- `Dirent`/`allocate_dirent` was a synchronous one-caller pointer/owner wrapper
  and became one owned `libuv.uv_dirent_t.new()` local at the scandir consumer.
- The `storage: value = owned` aliases in stream-byte and DNS-address
  construction added no lifetime or type information, so the constructors now
  receive `owned` directly in their `value` slots. The exact DNS source
  transformer in `spec/support/make_delayed_dns_callback_variant.lua` was
  updated with the source anchor.
- `SizedBytes`/`allocate_sized_bytes` was removed with an explicit
  `size_t <= LUA_MAXINTEGER` check before converting the libuv-reported
  capacity to the Titan `integer` required by `new_array`. The successful
  logical result remains `sizes[0]`, not `#owned`.
- `Bytes`, `Buffer`, and `AddressList` were retained. They carry pointers/owners across
  callback, queue, retry, or other long-lived state; their logical/view lengths
  may differ from allocation counts, and repeated pointer access occurs after
  the owned foreign type has deliberately been erased into a record.
- Process `argv` ownership and its explicit logical count were retained: its
  allocation includes the final null sentinel while public `argc` does not.
  Exact nominal facade adapters and shared read/run helpers were also retained;
  they serve repeated typed calls or multiple public operations rather than a
  sole-use forwarding layer.

### 17.7 Completed validation

- The combined nine-module `make stdlib` build passed after the final string
  and UV allocation edits.
- Focused public suites passed: PEG/relabel 15/15, string 8/8, string regex
  8/8, OS helpers 2/2, filesystem 3/3, and net/TCP 4/4.
- The PEG/string CI shard passed 31/31. Focused source/declaration/private-UV
  roster checks passed 4/4, the transformed delayed-DNS provider/port case
  passed 1/1, and the rockspec vendored-source pack/unpack case passed 1/1.
- The complete non-coverage library group passed 200/200 across 23 files:
  native/packaging 120/120, uv/timer/fs 35/35, net/OS 14/14, and PEG/string
  31/31.
- The source-pack and complete library runs used a temporary Git index under
  `/tmp` that removed the unstaged `captures.titan` entry. The real index hash
  was unchanged and its staged diff stayed empty.
- `git diff --check`, dead-declaration/reference searches, owned-array GC
  stress, and independent string/UV/full-diff adversarial reviews all passed.
  No manual macOS dispatch was requested or run for this cleanup.
