# Spread expressions

Spread expressions extend the finite/open expression-list machinery
([Flexible returns](flexible-returns.md#one-finiteopen-result-demand)) with a
non-contiguous producer. They add no run-time object, public ABI shape, or
generated helper function. The parser and checker build a shared carrier plus
projections; the coder emits the carrier setup and element reads directly in
the consuming function. The language rules are in
[Spread expressions](../language/spread-expressions.md).

## Parser and AST ownership

`ast.lua` has `ExpSubset(loc, exp, first, last)`,
`ExpSpread(loc, exp, first, last)`, and the checker-synthesized
`ExpSpreadIndex(loc, spread, index, _type)`. A comma-bearing bracket suffix is
parsed once, selecting an ordinary index or a range at the next delimiter.
Missing range bounds are `nil`.

Bare `...` is an expression atom (`baseexp`). After it, `[` selects
input-vararg index or range syntax; otherwise a token in the expression FIRST
set selects a collection-spread subject. The dispatch uses bounded token
lookahead and parses the subject once. `#...` stays distinct from length
applied to an indexed vararg. Prefix/suffix chains and expression lists use
fold captures.

The parser accepts non-tail markers and keeps them in the AST. Expression-list
adjustment and constructor checking reject unparenthesized spreads or varargs
outside the final expanding position. A plain collection subset
(`items[first, last]`) still needs an enclosing spread; the `Ast.ExpSubset`
checker arm rejects it elsewhere. Parentheses request one result: `(...)`,
`(...items)`, and `(...[first, last])`.

`defs.check_expression_list` (`parser.lua`) enforces the 100-item list limit
(`LIST_LIMIT`) for calls, returns, right-hand sides and generic-`for` tuples,
but accepts a 101st item when it is a final `ExpDots`, `ExpSpread`, or
`ExpSubset` of `ExpDots`. A trailing flexible-result call still counts among
the 100. Constructor field lists do not use this bound; they rely on the
container-capacity preflight below.

## Checker planning

`check_spread_marker` (`checker/expression_lists.lua`) checks the carrier
once, with no target container context. A spread whose subject is an
`ExpSubset` takes over that subject and its bounds. The subject kind is:

* `ExpDots`, resolved against the current function's `$vararg`. A collection
  spread of bare `...` with no range is rejected (`a collection spread cannot
  use bare '...' as its subject; use the vararg tail directly`).
* otherwise the checked subject type, which must be an exact `Type.Array` or a
  `Type.Map` with Integer keys. An Option subject is first forced with
  `tryforce`, as for any operation that dispatches on the underlying type.

It records:

* `_spread_kind`: `array`, `map`, or `dots`;
* `_spread_elem`: the exact element type `T`;
* `_spread_optional_type`: `T?` for finite projections;
* `_spread_optional_guard` and `_spread_open_guard`: the strict gradual-read
  guards for the optional and open representations. An element type without a
  sound guard is rejected;
* the checked and coerced integer bounds.

The carrier itself has effect-only `nil` type. It stays in `adjusted.exps` even
under zero demand, so the subject and bounds keep their source-order effects
and are evaluated once.

For finite demand, `adjust_explist` adds one `ExpSpreadIndex` per remaining
slot, all pointing at the same carrier through `.spread`. Each projection is
`T?`, nil-filling, and then gets the ordinary assignment adjustment to its
target. For open demand the carrier owns `_open_spread`, recording raw `T`, the
target element, and the first projection not consumed by the finite prefix.
The common adjusted-list fields (`open_source`, `open_type`, `open_target`,
`open_adjustment`, callable/Interface plans) then follow the same paths as
`ExpDots` and flexible call results.

Generic lowering (`checker/lowering.lua`) memoizes carriers by identity in
`state.spreads`, because the adjusted AST is a DAG. It lowers the subject and
each bound once, erases the carrier's element and target descriptors,
recomputes their guards, and redirects every `ExpSpreadIndex` to the same
lowered carrier. Generic argument and constructor finishing use the shared
open-source descriptor rather than tag-specific forks. Fixed generic formals
infer from the finite `T?` projection; only an open vararg formal receives raw
`T` evidence. A positional constructor nested in a generic call refreshes its
carrier and projections once later sibling evidence has closed the element
type.

Strict nonvariadic C consumers (direct foreign calls, C function-pointer calls,
allocation pseudo-calls) evaluate `adjusted.exps` in lexical order, so the
carrier runs once, but fill ABI arguments from `adjusted.fixed`; the carrier
never occupies a formal position. A spread cannot supply C variadic operands,
and no Titan run descriptor enters that ABI.

## Generated carrier and result run

`code_spread_carrier` (`coder/expressions.lua`) emits, in source order:

1. the stabilized Array or Map subject;
2. each explicit frozen bound;
3. the default upper bound (the subject's length) when needed;
4. one unsigned selected-count calculation.

The subject is evaluated once into an ordinary C temporary. Its elements are
read after the bounds run, and an open consumer reads them later still, so
the subject follows the rule for native inputs
([Calls](values-and-gc.md#calls-c-only-inputs-immediate-result-roots-and-vm-transport)):
`coder._stabilize_input_code` publishes it in a slot of this frame when it
has no stable root, for example when it was read from a record field that a
bound expression can overwrite. A subject that already has one (a local, a
parameter, a fresh constructor, a call result) gets no store.
Later bound evaluation cannot change the frozen temporary.

The range comparison is signed, but the inclusive distance uses Lua's unsigned
arithmetic (`l_castS2U`), so a hostile `first`/`last` pair cannot trigger C
signed overflow; a full-range distance saturates at `LUA_MAXUNSIGNED`. A
reversed range selects zero. The count stays `lua_Unsigned` until its consumer
has checked capacity.

Finite `ExpSpreadIndex` nodes read from the prepared carrier. An open carrier
publishes the compiler-side result-run record with a `read` closure instead of
a contiguous `args[start + i]` buffer. `coder._code_open_source` and
`coder._convert_result_run_element` (`coder/calls.lua`) use that reader, so
constructors, calls and returns keep their existing adjustment and destination
code. The closure exists only in the compiler and emits C statements into the
current function; no C auxiliary is generated.

## Element reads and GC ownership

Array reads follow the raw positive-index path of ordinary typed Array
indexing and apply the checker's strict guard. The Array subject owns its
stored collectables until the destination publishes them. Two cases need a
root of their own:

- An Array element guard that can discover an Interface may allocate a fresh
  wrapper the subject does not own. A finite or immediately consumed read
  publishes that wrapper in one reusable result slot; a buffered open sink
  gives every still-live wrapper a distinct result slot.
- A variadic callee can overwrite the Array's slots while it holds the
  elements in its descriptor. The array run is marked `callee_mutable` when
  its elements are collectable, and `coder._emit_open_vararg_struct`
  publishes each element in the call site's traced range. A flexible `return`
  and a constructor tail need no such range: no user code runs between the
  read and the destination's own publication.

Variadic reads borrow the input descriptor's elements, which the function's
caller roots. A finite `ExpSpreadIndex` is a
nil-filling `T?` projection whose target adjustment may force presence; only an
open vararg run keeps the raising out-of-range read.

Map reads use `get_table_key` (`coder/statements.lua`), not `luaH_getint`
alone, so a raw miss follows `luaV_finishget`, including table- and
function-valued `__index`, before the strict typed guard. For a function-valued
metamethod, `luaT_callTMres` saves the result address across stack growth,
calls through `luaD_callnoyield`, and moves the result back into that Lua stack
slot. The lookup result is already traced and is not copied to a second root.

An immediate-consumption loop may reuse one lookup result slot after copying
the value into the traced destination. A native sink that holds several
collectable C values before consuming them keeps each still-live lookup result
in a distinct Lua stack slot. Every allocating read or conversion rebases from
`_base_off` before continuing.

An allocating adjustment owns its cast anchor: the ordinary static cast slot
for an immediate consumer, or the sink's current indexed slot for a
runtime-sized buffered sink, where the cast publishes its final wrapper once.
A slot reserved only to retain a raw Map read is kept separate from a
nonallocating adjustment; after conversion the sink publishes the result only
when its output type requires it.

## Sink-specific preflight

Every runtime-sized sink checks the complete selected remainder before its loop
and before any destination allocation or partial write:

* native variadic input and flexible output: the remaining `TITAN_VARARG_MAX`
  capacity after the fixed prefix;
* Array and positional integer-Map constructors: the remaining
  `TITAN_ARRAY_MAX_CAPACITY`;
* finite generic VM result requests: the independent 250-result bound.

The success branch is `TITAN_LIKELY`. Only after the check may generated code
narrow a count to `int` for an ABI field or loop.

## Regression ownership

Parser spellings and disambiguation are in `spec/parser_spec.lua`. Checker
acceptance, rejection, planning and generic erasure are in
`spec/checker/spread_expressions_spec.lua`; generated C and run-time range,
metamethod, evaluation-order, capacity and GC behavior are in
`spec/coder/spread_expressions_spec.lua`. Both compiler files are listed once in
`spec/support/ci_compiler_test_groups.txt`.
