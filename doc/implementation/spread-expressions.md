# Spread expressions

Spread expressions extend the existing finite/open expression-list machinery
with a non-contiguous producer. They do not add a run-time object, public ABI
shape, or generated helper function. The parser and checker construct a shared
carrier plus projections; the C generator emits the carrier setup and element
reads directly inside the consuming function.

## Parser and AST ownership

The AST retains `ExpSubset(loc, exp, first, last)`,
`ExpSpread(loc, exp, first, last)`, and checker-synthesized
`ExpSpreadIndex(loc, spread, index, type)`. A comma-bearing bracket suffix is
parsed once, selecting an ordinary index or range at the next delimiter.
Missing range bounds are represented by `nil`.

Bare `...` is now an expression atom. After it, `[` selects input-vararg
index/range syntax; otherwise a token in the expression FIRST set selects a
collection-spread subject. This dispatch uses bounded token lookahead and
parses the selected subject once. The explicit `#...` count form stays distinct
from length applied to an indexed vararg. Prefix/suffix and expression lists
use fold captures rather than recursive list captures.

The parser accepts non-tail markers and preserves them in the AST. Expression-
list adjustment and constructor checking reject unparenthesized spreads or
varargs outside the final expanding position. A plain collection subset still
requires an enclosing spread. Parentheses instead request one result, including
`(...)`, `(...items)`, and `(...[first, last])`.

During checking, a spread whose subject is an `ExpSubset` takes ownership of
its subject and bounds. Finite projections share that one carrier through
`ExpSpreadIndex.spread`; the subject and both bounds are evaluated once. These
syntax changes preserve the existing finite/open demand and code-generation
plans described below.

## Checker planning

`check_spread_marker` checks the carrier once without a target container
context, then applies the ordinary `tryforce` Option unwrap before selecting
the subject kind. It accepts the resulting exact `Type.Array`, an exact
`Type.Map` whose key type is Integer, or an `ExpDots` resolved against the
current function's `$vararg`. It records:

* `_spread_kind`: `array`, `map`, or `dots`;
* `_spread_elem`: the exact element type `T`;
* `_spread_optional_type`: `T?` for finite projections;
* strict gradual-read guards for the optional and open representations;
* the checked/coerced explicit integer bounds.

The carrier itself has effect-only `nil` type. It must remain in
`adjusted.exps` even under zero demand so the subject and bounds retain their
source-order effects.

For finite demand, `adjust_explist` adds one `ExpSpreadIndex` per remaining
slot. Each projection is initially `T?`, is marked for nil fill, and then
receives the ordinary checker-owned assignment adjustment to its target. For
open demand, the carrier also owns `_open_spread`, whose descriptor records
the raw `T`, target element, and the first projection not already consumed by
the finite prefix. The common adjusted-list fields (`open_source`,
`open_type`, `open_target`, `open_adjustment`, and callable/interface plans)
then use the same paths as `ExpDots` and flexible call results.

Generic lowering memoizes carriers by identity because the adjusted AST is a
DAG. It lowers the subject and each bound exactly once, erases the carrier's
element/target descriptors, recomputes their guards, and redirects every
`ExpSpreadIndex` to that same lowered carrier. Generic argument and constructor
finishing use the shared open-source descriptor instead of tag-specific
`ExpDots`/`ExpCall` forks. Fixed generic formals infer from the finite `T?`
projection, while only an open vararg formal receives raw `T` evidence. A
positional constructor nested in a generic call refreshes its carrier and
projections with the active inference context after later sibling evidence has
closed the element type.

Strict nonvariadic-C consumers retain the same split. They evaluate
`adjusted.exps` in lexical order so the carrier runs once, but populate ABI
arguments from `adjusted.fixed`; the carrier itself never occupies a formal
position. The same rule covers direct foreign calls, C function-pointer calls,
and allocation pseudo-calls. This is finite expression-list lowering only. C
variadic operands keep their independent explicit-scalar lowering and cannot
be supplied by a spread; no Titan run descriptor enters that ABI.

## Generated carrier and result run

`code_spread_carrier` emits, in source order:

1. the frozen Array/Map subject;
2. each explicit frozen bound;
3. the default upper length when needed;
4. one unsigned selected-count calculation.

The frozen subject is the ordinary implicit C temporary produced by expression
lowering to evaluate that expression exactly once. That temporary is not a new
traced slot: any root required by the value is already established by the
generated subject evaluation through its allocation/result publication,
semantic home, or VM stack home. Later bound evaluation cannot mutate the
frozen temporary. Spread lowering neither re-roots the subject nor adds a
second lifetime mechanism.

The range comparison is signed, but the inclusive distance is calculated with
Lua's unsigned integer operations so a hostile `first`/`last` pair cannot
trigger C signed-overflow undefined behavior. A reversed range publishes zero.
The count stays `lua_Unsigned` until its consumer has checked the appropriate
capacity.

Finite `ExpSpreadIndex` nodes read from the prepared carrier. An open carrier
publishes the existing compiler-side result-run record with a `read` closure
instead of a contiguous `args[start + i]` buffer. `_code_open_source` and
`_convert_result_run_element` use that reader, so constructors, calls, and
returns retain their existing adjustment and destination code.

The closure is a Lua compiler value only. Its output is C statements in the
current generated function; no callable C auxiliary is emitted. This keeps the
feature within the rule that any generated-code callable auxiliary would have
to live exclusively as `static inline` in `titan-runtime/titan.h`.

## Element reads and GC ownership

Array reads follow the same raw positive-index path as ordinary typed Array
indexing and apply the checker-supplied strict guard. The frozen Array subject
owns its stored collectables until the destination publishes them. A delayed
Array view whose element guard can discover an Interface is the exception: the
guard may allocate a fresh wrapper that the subject does not own. A finite or
immediate-consumption read publishes that wrapper in one ordinary reusable
result slot; a buffered open sink supplies a distinct result slot for every
still-live wrapper. Variadic reads borrow the input descriptor's already
established provenance. A finite `ExpSpreadIndex` is a nil-filling `T?`
projection whose later target adjustment may force presence; only an open
vararg run retains the direct raising out-of-range read.

Map reads deliberately use `get_table_key`, not `luaH_getint` alone. A raw miss
therefore follows `luaV_finishget`, including table- and function-valued
`__index`, before the strict typed read guard is applied. For a function-valued
metamethod, `luaT_callTMres` saves the supplied result address across stack
growth, calls through `luaD_callnoyield` from generated Titan C, and moves the
result back into that Lua stack slot. The lookup result is already traced; it
must not be copied to a second spread-specific root.

An immediate-consumption loop may reuse one such lookup result slot after it
has copied the value into the traced destination. A native sink that retains
several collectable C values before consuming them instead leaves each
still-live lookup result in a distinct ordinary Lua stack result slot. The
untraced variadic descriptor never becomes an owner. Every allocating read or
conversion rebases stack addresses from `_base_off` before continuing.

An allocating adjustment still owns its cast anchor. For an immediate
consumer it uses the ordinary static cast slot; for a runtime-sized buffered
sink, the sink selects the current indexed slot and the cast publishes its
final wrapper there exactly once. Call-input and flexible-return lowering do
not add a post-cast publication. A slot reserved only to retain a raw Map read
is kept separate from a nonallocating adjustment; after conversion, the sink
publishes the assigned result only when its output type itself requires it.

## Sink-specific preflight

Every run-time-sized sink checks the complete selected remainder before its
loop and before a destination allocation or partial write:

* native variadic input and flexible output use the remaining
  `TITAN_VARARG_MAX` capacity after their fixed prefix;
* Array and positional integer-Map constructors use the remaining
  `TITAN_ARRAY_MAX_CAPACITY`;
* finite generic VM result requests keep their independent 250-result
  boundary.

The successful branch uses Titan's likely-path convention. Only after the
check may generated code narrow a count to `int` for an existing ABI field or
loop. The parser's separate expression-list bound is unrelated: calls,
returns, RHS lists, and generic-`for` tuples may have 100 fixed-position
written items plus one final parser-tagged `ExpDots` or `ExpSpread`. A trailing
flexible-result call still counts among the ordinary 100 even when checking
later treats it as open. Constructor field lists do not use this parser bound
and instead rely on their container-capacity preflight.

## Regression ownership

Parser spellings and disambiguation live in `spec/parser_spec.lua`. Checker
acceptance, rejection, planning, and generic erasure live in the topical
`spec/checker/spread_expressions_spec.lua`; generated-C and run-time range,
metamethod, evaluation-order, capacity, and GC behavior live in
`spec/coder/spread_expressions_spec.lua`. Both topical compiler files belong
exactly once in `spec/support/ci_compiler_test_groups.txt` so Linux compiler
coverage includes the feature without putting standard-library behavior under
LuaCov.
