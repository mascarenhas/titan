# LPegLabel embedding and `titan.peg`

`titan.peg` is a typed Titan folder module backed by a private, statically
incorporated LPegLabel engine. The engine is standard-library payload rather
than a public C dependency: neither its archive, headers, Lua table, registry
identity, nor raw pattern userdata is part of the installed Titan SDK.

The user-facing API is documented in the
[PEG standard library](../language/standard-library-peg.md).

## Source provenance

The tracked snapshot under `vendor/lpeglabel/` comes from:

| Item | Pinned value |
| --- | --- |
| upstream | `sqmedeiros/lpeglabel` |
| release | `v1.6.2-1` |
| commit | `912b0b9e8641074408ffc2259e069b188e0c717b` |
| commit date | `2023-05-02T14:22:18-03:00` |
| release archive SHA-256 | `5511d2704de4580c5b79b100c2daec5e773db58be9c2239e49ea2d9da2decf67` |

The production snapshot contains the five upstream C units and every header
they include. `relabel.lua`, `test.lua`, `testlabel.lua`, and
`testrelabelparser.lua` are pinned test inputs only. The private native harness
loads those files to verify upstream behavior; no upstream Lua file is
installed or used by production. Production relabel is a reviewed Titan
translation.

The release and runtime version strings are intentionally not identical.
Pinned `lpltypes.h` still defines `VERSION` as `1.6.1`, so the table opened by
this source reports `LPegLabel 1.6.1` and `titan.peg.version()` returns that
native string. `vendor/lpeglabel/UPSTREAM.md` and the Make configuration
record the authoritative release tag and commit independently.

Upstream headers and the vendor license remain with the snapshot.
`THIRD_PARTY_NOTICES.md` records the static incorporation and the Titan relabel
translation, while the installed notices include the separate LPegLabel and
LPeg license texts.

The snapshot also carries Lua 5.5.1's constant-time UTF-8 lead-byte guard in
LPegLabel's same-shaped decoder: bytes `0xF8..0xFF`, which would require an
unsupported five-or-more-byte sequence, are rejected before the continuation
loop. This preserves the existing accepted UTF-8 domain while bounding hostile
invalid input at the native boundary.

## Native namespace and registry identity

The combined `titan.so` provider is promoted with `RTLD_GLOBAL`, and the
members of `titan.a` are flattened into static consumers. Hidden visibility
alone therefore cannot isolate generic upstream definitions such as
`compile`, `match`, `fixedlen`, `runtimecap`, and `getcaptures`.

`titan_lpeglabel_namespace.h` remaps every non-static definition in all five
translation units, including `LPEG_DEBUG` printers, to the
`titan_lpeglabel_*` namespace. It also renames:

```text
luaopen_lpeglabel -> titan_lpeglabel_open
```

The namespace header is included by the shared upstream `lpltypes.h`, so the
rename happens while compiling source. There is no `objcopy`, linker alias,
symbolic link, or platform-specific post-processing step. All five units also
compile with `-fvisibility=hidden`, and the declaration of the private opener
uses hidden visibility where the compiler supports it.

The two process-visible Lua registry strings are revisioned and private:

```text
titan.peg.lpeglabel.912b0b9e.pattern
titan.peg.lpeglabel.912b0b9e.maxstack
```

Consequently, an external LPegLabel installation has a different pattern
metatable and a different per-state stack setting. Loading external
LPegLabel before or after `titan.peg` does not merge either engine's state;
cross-engine pattern use fails the owning engine's type check.

## Opening one private engine per Lua state

The canonical main `titan/peg/peg.titan` owns module state and calls
`titan_lpeglabel_open(L)` directly from its sole initializer. It expects the
opener to report one result and leave its module table on top, captures that
table as a traced module value, and restores the entry stack top.

It deliberately does not use `luaL_requiref`, write
`package.loaded.lpeglabel`, or publish the native table. Lua observes only
the generated `titan.peg` logical module Udata and its public interface.

Initialization caches the native constructors and operations as traced module
values:

```text
P S R utfR V B T
C Cc Cmt Cb Carg Cp Cs Ct Cf Cg
match locale setmaxstack
```

It also obtains the pattern metatable through the private registry key and
caches `__mul`, `__add`, `__sub`, `__len`, `__unm`, `__pow`, and `__div` as
the raw operations behind Titan's named combinators. An identity-only Lua
table is retained as the match-success sentinel.

These roots belong to the generated module userdata and are therefore
per-Lua-state. `set_max_stack` changes the value at the private max-stack
registry key for that state only.

## Typed folder-module boundary

The canonical main defines every public record, method, and function. In
particular, its opaque records are:

```titan
record Pattern
  local raw: value
  local tree_size: integer
end

record Rule
  local name: string
  local pattern: Pattern
end

record Definition
  local name: string
  local raw: value
  local tree_size: integer
end
```

`Pattern.raw` is always a traced `value` owned by the private engine.
`tree_size` is conservative construction accounting, not a raw native field.
A pattern `Definition` retains both so the relabel parser can safely rewrap
the private native pattern without losing the construction bound; a dynamic
definition records `-1` instead. The contributors expose no top-level public
declarations. Public constructor, combinator, capture, definition, matching,
and relabel-convenience implementations live directly in the canonical main.
The contributors retain only module-local native-boundary operations,
conservative size projections, diagnostics, caches, callbacks, and
parser/compiler helpers. `relabel_parser.titan` assembles the self-hosted
expression grammar from operations in that shared module scope.

The folder ensemble is parsed separately and then combined into one AST and
one checker/code-generator pass. With `--output out`, its generated files are:

```text
out/titan/peg/peg.c
out/titan/peg/peg.o
out/titan/peg/peg.ffi.h
out/titan/peg.lua
```

There is one `titan.peg` logical ABI/types protocol and no module, provider,
or shim per contributor.

The wrapper keeps public types tighter than the native Lua API:

* patterns do not use LPeg's implicit string/number coercion;
* runtime, match-time, fold, and function captures use callable Titan types
  and reach the engine through internal adapter closures with the exact raw
  callback protocol it requires;
* query capture uses `{value: value}`, preserving ordinary Lua table identity
  and `__index`;
* grammar collections use `{Rule}` and are traversed as Titan Arrays;
* public rule names and labels are strings, including empty,
  numeric-looking, and binary strings.

An Array's canonical Lua representation is its userdata proxy, so an ordinary
Lua table cannot cross the grammar or definition-collection boundary. This is
the same nominal container distinction used by other Titan APIs, rather than a
module-specific raw-table scan.

Ordinary Titan call adjustment remains authoritative. Nil fills omitted fixed
slots and evaluated surplus arguments are discarded. A function is variadic
only where the engine consumes a run, and callback types use variadic inputs
or flexible outputs only where the native callback protocol is genuinely
open. Parser- and regex-specific callbacks whose construction guarantees a
fixed number of capture slots keep fixed parameter lists; directional callable
adjustment admits those extra `value` slots because its named shape rules can
nil-fill them and they accept the generic capture tail. LPegLabel always stores the
internal exact adapter closure required by its raw callback protocol. The
adapter captures the user-supplied function-typed value and invokes it through
Titan's ordinary callable machinery: exact Titan sources and realized
target-tagged adjustment wrappers can use the exact native path; unchanged
branded mismatches use their strict declaration/relay entry; and Lua functions,
C functions, and `__call` objects use the ordinary Lua path. There is no `_raw_type` probe or eager raw-function validation of that
captured value; a noncallable value fails only if the engine actually invokes
the adapter. The relabel adapters for dynamic definition values remain
genuinely variadic/flexible because their capture arity and result count are
open.

## Construction accounting and string labels

Pinned LPegLabel defines `MAXPATTSIZE` as `SHRT_MAX - 10` but does not enforce
that limit consistently before narrowing sizes. Titan treats 32757 tree slots
as a conservative public maximum and checks every constructor before calling
the engine.

Every `Pattern` records its projected size. Checked additions account for
fold/capture/predicate overhead; literal and `any` constructors use the
native formulas; repetition validates multiplication before constructing
`p ^ n`; grammar sums rule trees and its table overhead. `at_most(p, 0)` is
handled as empty success so C negation cannot turn `-0` into the native
zero-or-more operation.

The wrapper also validates the pinned narrow domains before C conversion:
look-behind is capture-free, fixed-length, and at most 255 bytes; grammar
count is at most 1000; argument and capture selectors fit signed short; and
max-stack values fit `1..INT_MAX/100`.

Titan's public rule names and labels are strings. It passes their exact bytes
to the engine without a private prefix or integer encoding. Empty strings,
numeric-looking strings, and embedded NUL therefore remain distinct.

Upstream `lpltree.c` converted an integer-looking label back to an integer
without remembering whether the caller originally supplied a string. The
vendored patch instead preserves the supplied Lua type. This lets Titan pass
`"0"` or `"01"` and receive those exact strings, while the unmodified upstream
integer-label behavior remains available to the private native compatibility
harness. Titan's public boundary rejects integer labels before reaching the
engine. The same patch makes grammar collection recognize only the integer
key `1` as the positional start slot; upstream's numeric coercion would
otherwise skip a distinct recovery rule named `"1"`.

The label `"fail"` is the engine's ordinary-failure marker. The public
`throw("fail")` constructor therefore returns the same pattern as `fail()`
instead of constructing a labeled throw. Choice, repetition, grammar recovery,
the returned failure triple, and module-level leftmost search all consequently
treat it as ordinary failure.

## Match adapter and failure positions

The shared single-attempt adapter constructs this private pattern around the
user's pattern:

```text
constant(success_sentinel) * pattern * position_capture()
```

The cached native callable has the precise internal type:

```text
function (value, string, integer, ...: value): (value, value, ...: value)
```

It is a Lua C closure, so Titan's generic callable path invokes it directly
and propagates its ordinary error. The two fixed result slots are deliberate.
A capture-free success returns the sentinel and final position; a failure
returns `nil`, a label, and a position. On a success with captures, the second
fixed slot holds the first user capture and the flexible tail holds the
remaining captures followed by the final position. Thus a successful
200-capture match uses the second fixed slot for capture 1 and exactly 200
flexible results for captures 2 through 200 plus the position; it does not
exceed Titan's flexible-tail bound.

The call is captured directly into a traced `{value}` Array. Its final
position makes trailing nil user captures observable in the Array's indexed
run, while leading and interior nils retain their exact slots. A sentinel
result identifies success independently of those contents. The adapter removes
the final position from the public capture run and retains it separately as
`after`; a bounded helper then projects the exact capture slots.
`Pattern:match` preserves the anchored API: captures become its fixed `value`
prefix and flexible tail, while a capture-free success returns `after`.

Module-level `match` reuses the same attempt result while trying successive
byte positions through `#subject + 1`. It never matches a successful candidate
twice, so match-time effects are not repeated. Ordinary failure advances one
byte; a labeled failure commits the search. Success produces a `Match` with
inclusive `first`/`last` and the untouched capture Array/count.
`Match:values()` projects exactly those captures and produces zero values for
a capture-free candidate. Because search bookkeeping is not represented by
native captures, all 200 user capture slots remain available; a larger run
raises at the Titan boundary.

LPegLabel reports failure as a triple containing a position relative
to the normalized initial pointer. The adapter adds `start - 1`, producing
the documented absolute farthest-failure or throw position. Initial positions
are normalized in checked Titan arithmetic before the native call, avoiding
negation of Titan's minimum integer.

## Stack, roots, callbacks, and errors

Raw Lua C API use is confined to opening and validating the private engine and
reading its registry metatable. Each locale refresh creates its relabel cache
as a typed `{string: Pattern}` Map, passes that same Map through the public
`titan.gc.weak` boundary using one local `{value: value}` view, and then assigns
it directly to module state. Replacing the cache is what prevents
locale-dependent compiled sources from surviving `update_locale`; PEG no
longer duplicates the raw metatable setup owned by `titan.gc`. Each remaining
raw helper snapshots `lua_gettop(L)`, transfers any surviving collectable to a
traced Titan value, and restores the exact saved top with `defer`. The complete
narrow allowlist is recorded in [Lua C API FFI
follow-up](ffi-lua-api-followup.md).

Pattern construction, matching, and callbacks do not manually manipulate the
Lua stack. They call precisely typed cached Lua callables through Titan's
generated generic callable path, which supplies its own roots, result
adjustment, and error propagation.

The private engine Map, cached native functions, locale patterns, relabel
parser, weak cache table, and success sentinel are module-state roots. Every
`Pattern.raw` is traced. LPegLabel's
pattern userdata uservalue table in turn roots constant captures, grammar
tables, query tables, and callback functions.

No raw pointer into a subject string, stack slot, or wrapper lives across an
allocation or callback. Titan code retains the traced owner and a byte offset,
then derives an address again when needed. The vendored VM can retain its own
instruction, capture, and subject pointers according to its native protocol
because the immutable Lua string and pattern userdata remain rooted.

Runtime patterns and match-time captures execute while matching. Fold and
function captures execute while delayed captures are evaluated. They can
allocate, run collection, and raise. The native call has no yielding
continuation, so a callback's attempt to yield becomes a normal Lua boundary
error. A noncallable function-typed value raises at the same point, not while
the pattern is constructed; if matching never reaches that callback, it does
not raise. Calls are serial on the current Lua thread; there is no
process-global matching state.

## Relabel translation

Production relabel parses the pinned notation with patterns built through the
public named `titan.peg` operations. It does not import `titan.string`, call
private native metamethods directly, or install a separate `titan.peg.re`
logical module.

The independent `titan.url` module dogfoods that public surface: its
initializer calls `peg.compile` once on a Relabel-source RFC 3986 grammar and
retains the resulting `peg.Pattern` for later synchronous parses. URL owns its
labels, captures, policy, and normalization; it does not reach the private
LPegLabel engine directly.

`Definition` distinguishes a pattern definition, whose private raw pattern
must enter the native definition table, from a retained dynamic value used by
replacement and callback suffixes. Definition and grammar collections are
Titan Arrays traversed from 1 through their Array length. Duplicate names are
rejected. Definition names otherwise remain arbitrary strings; a name that
the relabel notation cannot spell is accepted but inert.

The relabel expression language's `->` suffix preserves its dynamic
definition-value behavior and performs one ordered classification: string,
value satisfying `is integer`, Map, then function fallback for every remaining
value. `is integer` asks whether the corresponding checked `as integer` cast
would succeed, so a representable integral float selects the capture-index
branch. Testing Map before the fallback preserves table-query behavior for a
table that also has `__call`. The fallback always builds the native adapter
and does not use `_raw_type` to preflight its captured replacement; Titan's
generic callable path reports a noncallable value only if capture evaluation
invokes it. Dynamic callback suffixes use the same deferred adapter rule.

The parser captures both identifier and decimal throw labels as strings and
passes those bytes directly to `throw`; it performs no numeric decoding.
Consequently `%{01}` reports `"01"`, while `%{fail}` takes the same ordinary
failure path as a directly constructed `throw("fail")`.

The public `gsub` API is deliberately narrower. Its replacement has exact type
`function (string): (string)`; `%0` first reduces any candidate captures to the whole
matched substring, and an exact native-protocol adapter calls the replacement.
Source candidates reuse the ordinary weak compiled-pattern cache, while each
call constructs the small replacement wrapper needed to retain its callback.

The parser retains byte offsets in its internal syntax diagnostics. A labeled
parse failure is turned into the public:

```text
PEG syntax error [label] at Lx:Cy (byte p): message
source line
caret
```

format. `line_column` counts one-based bytes, treats CRLF as one line ending,
and accepts positions through `#subject + 1`. This intentionally repairs the
pinned Lua helper's inconsistent newline/EOF offsets while the private native
harness continues to test the unmodified upstream fixture.

One per-state weak-value cache holds definition-free source compilations
shared by `compile`, module-level `match`, and `gsub`. The cache table itself
is rooted in module state, but its compiled values remain collectable; a
traced temporary keeps the selected entry alive during use. `update_locale`
rebuilds the predefined character classes from a new `locale()` snapshot and
clears that cache.

## Build and provider integration

`make lpeglabel` compiles, validates, and archives exactly these members in
upstream rockspec order:

```text
lplcap.o
lplcode.o
lplprint.o
lpltree.o
lplvm.o
```

The output is:

```text
lpeglabel-build/libtitan-lpeglabel.a
```

The five objects depend on their vendored sources, private headers, and the
selected public Lua headers. Ordinary `ar rcs` and `ranlib` build the archive.
Clean the private build directory before changing tools or flags; Make uses
source and header timestamps without configuration receipts or archive rescans.

The standard provider's metadata-free `-X` payload has this order:

```text
ltitanlib.o
libtitan-lpeglabel.a
[bundled libuv.a]
libtitan-llhttp.a
libtitan-sqlite3.a
[bundled OpenSSL libssl.a + libcrypto.a]
```

The source build invokes one compiler process for the twenty-three logical roots:

```text
titan.coroutine titan.uv titan.async titan.timer titan.io titan.fs
titan.net titan.ssl titan.url titan.http titan.websocket titan.os titan.path titan.peg titan.string
titan.math titan.lua titan.iteration titan.gc titan.test titan.reflect titan.sqlite3 titan.json
```

The paired `titan.so`/`titan.a` has twenty-three logical ABI/types protocols,
twenty-three archive metadata keys, and twenty-three generated Lua shims. Bare native
support adds a twenty-fourth DSO opener. LPegLabel contributes no logical key:
its five members are
force-carried into both provider forms solely as private native payload.

The archive and headers are not copied into `$ROCKS_TREE/lib` or
`$ROCKS_TREE/include`. The private embedding installs no `lpeglabel.so`,
`relabel.lua`, child DSO, or extra Titan shim. An external `lpeglabel.so`
present as the compiler's LuaRocks dependency remains separately owned and is
not used by `titan.peg`. The source rock contains the vendored inputs so
the default `all` build target can build the private archive and link it into the
standard provider using the in-tree compiler and private bootstrap. The
install pass stages the completed provider in the retained package payload;
the copy-only `post_install` helper publishes it. The installed SDK
does not retain the private archive.

LuaRocks declares `lpeglabel >= 1.6.2` for the compiler's own parser.
That compiler-owned dependency is independent of the vendored standard
module: a deployed `titan.peg` pattern never dynamically links to or requires
the external module.

The generated providers are validated for exact symbols, twenty-three metadata
keys, all twenty-four Lua openers, and absence of an LPegLabel dynamic
dependency. Isolation
tests load private and external engines in both orders, use both pattern
families, vary their max-stack settings independently, and reject cross-engine
patterns.

Standard-library installation copies the completed provider pair, generated
shims, exact `titan.test` compiler source, licenses, and optional macOS dSYM.
The explicit packaging and dependency-mode gates retain protocol, symbol,
metadata, and native-dependency checks. Callers clean stale installations and
use a fresh versioned tree when changing ABI or platform.
