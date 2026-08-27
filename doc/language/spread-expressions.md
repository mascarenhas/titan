# Spread expressions

A spread expression expands an Array, an integer-keyed Map, or a selected
range of the current function's variadic arguments into the surrounding
positional expression list. It is written with `...` immediately before the
subject:

```lua
function append(dst: (integer, ...: integer) -> (), xs: {integer}): ()
    dst(0, ...xs)
end

function middle(xs: {string}): {string}
    return {...xs[2, #xs - 1]}
end

function forward_middle(...: string): (...: string)
    return ...[2, #... - 1]
end
```

Only the last item of a positional expression list can expand. An earlier
multiple-return call is an ordinary scalar expression. An explicit spread
spelling may parse earlier so the checker can report that placement error;
bare variadic `...` remains syntactically restricted to the tail. The subject
and bounds are nevertheless evaluated exactly once even when the consumer
requests no elements.

Bare `...` is a list-tail marker, not a general expression operand, so
`expression + ...` is a syntax error. At the start of a list item, however,
`...` followed by an expression is the collection-spread form. This includes
an expression beginning with unary `-` or `~`: `... -1` spreads the subject
`-1` and is then rejected because an integer is not a container. Write
`(...) - 1` to subtract from the single adjusted vararg value. Parentheses can
also delimit a unary-leading subject explicitly, as in `...(-expression)`;
the normal Array/Map subject rule still applies.

## Subjects and syntax

The complete forms are:

```text
...subject
...subject[, last]
...subject[first,]
...subject[first, last]

...[, last]
...[first,]
...[first, last]
```

For the first four forms, let `S` be one of these accepted container types:

* an Array `{T}`, including `const {T}` and `const? {T}` views;
* an integer-keyed Map `{integer: T}`.

The subject's checked type may be `S` or `S?`. Every accepted Option subject is
auto-unwrapped once, with the ordinary run-time nil check; this includes
`const {T}?` and `const? {T}?` as well as mutable Arrays and integer-keyed Maps.
The compiler does not infer or apply a target-directed conversion before
deciding whether the subject is an Array or a Map. A written cast remains an
ordinary part of the subject expression and may explicitly produce an accepted
type. Without such a cast, a `value`, a C array, or a Map with any other key
type is rejected.

The last three forms select from the current function's `...: T` input run.
They are legal only inside that variadic function. A bare `...` without a
comma-bearing range keeps its existing meaning; `...[index]` is still the
ordinary scalar, raising variadic index operation. Because that indexed form
is an explicit scalar expression, it may itself be a collection subject:
`... ...[index]` spreads the Array or integer-keyed Map stored in that vararg
slot. A second bare `...` is not an expression, so `......` remains invalid.

Ordinary suffixes remain part of the subject expression. For example,
`...groups[i]` first performs the ordinary optional `groups[i]` read,
auto-unwraps it with a run-time presence check, and then spreads the resulting
Array or integer-keyed Map. A comma-bearing suffix such as `xs[first, last]`
is not a standalone slice value. A direct `...[first, last]` at the end of a
positional list is promoted to a spread; in any scalar or earlier position the
checker rejects the subset expression rather than assigning it a value.

## Closed ranges

Spread ranges are 1-based, closed, and inclusive. An omitted lower bound is 1;
an omitted upper bound is the subject's length. Thus `...xs` and
`...xs[1, #xs]` select the same indices, subject to the fact that the former
evaluates `xs` only once.

Each explicit bound must be an `integer` or be implicitly convertible to one.
Evaluation is left to right:

1. evaluate and retain the subject, unless the subject is the current `...`;
2. evaluate an explicit lower bound;
3. evaluate an explicit upper bound, or obtain the subject length for a
   default upper bound;
4. read the selected elements in increasing index order.

Every step happens once. For an integer-keyed Map, the default upper bound uses
ordinary Map length semantics, including `__len`, and each selected element
uses ordinary Map indexing semantics, including `__index`. Array length and
indexing retain the normal positive-index and hole behavior. A range whose
lower bound is greater than its upper bound is empty.

## Finite and open consumers

The surrounding expression list determines how much of a spread it consumes.
The same positional contexts that adjust a trailing `...` or flexible-result
call accept a spread:

* call arguments;
* declarations and assignments;
* `return` values;
* the tuple of a generic `for ... in`;
* the final positional field of an Array or exact integer-keyed Map
  constructor.

A finite consumer asks for a fixed number of remaining positions. The compiler
models each requested spread position as `T?`, because the selected range or
container may not supply that position. Normal assignment adjustment then
decides the outcome: an optional destination can receive `nil`, while a
required destination forces a present value and raises if the position is
absent.

```lua
function first_two(xs: {integer}): (integer, integer?)
    local first: integer, second: integer? = ...xs
    return first, second
end
```

An open consumer keeps the selected run-time length and consumes elements as
`T`, not `T?`. A missing Array/Map entry raises when `T` excludes `nil`; when
`T` admits `nil` (notably `value`), the missing entry is delivered as `nil`
without shortening the run. An explicit variadic range that reaches outside
the available run always raises when that element is read. An empty range
contributes no elements.

```lua
function collect(xs: {integer}): {integer}
    return {10, ...xs[2,]}       -- every selected value is appended
end

function relay(sink: (...: string) -> (), xs: {string}): ()
    sink(...xs)                  -- forwards the complete selected run
end
```

Only the final expression can expand. A preceding scalar is evaluated first
and contributes one value. An explicit spread parsed before another positional
item is rejected by the checker. A spread cannot be used in a computed Map
field, record field, named argument, condition, operator, or parenthesized
scalar position.

A direct call to a nonvariadic C function, a call through a nonvariadic C
function pointer, or a C allocation pseudo-call such as `T.new_array(...)`
consumes a spread only through its ordinary finite formal positions: Titan
evaluates the carrier and passes exactly one converted scalar for each C
parameter. C variadic arguments are a separate C ABI facility, not a Titan
open-run consumer. A spread cannot supply the C `...` operands. Individually
written scalars and finite, statically visible results from a trailing Titan
call retain their existing C-vararg conversion and promotion rules.

## Capacity limits and errors

The destination's existing limit applies to the part it owns:

* a Titan input-vararg run or flexible-result tail contains at most 200
  homogeneous tail values. Fixed parameters and fixed results are outside this
  count, while explicit scalar or finite values already placed in that tail
  consume part of its capacity;
* an Array or positional integer-keyed Map remains bounded by the container's
  maximum capacity, including every positional value before the spread;
* the separate finite generic-call result limit remains 250 values.

The generated code checks a run-time-sized spread against the applicable
remaining capacity before reading any of its elements. An oversized run raises
instead of partially updating the destination. These limits do not change the
parser's independent bound for expression lists in calls, returns, assignment
and declaration right-hand sides, and generic `for ... in` tuples: at most 100
ordinary written expressions may precede a separate trailing bare `...` or
open spread marker. A trailing call remains one of those 100 expressions.
Constructor field lists do not use this parser bound; their container capacity
is checked separately.

See [Variadic parameters](variadic-parameters.md) for bare `...`, `#...`, and
`...[index]`; [Flexible returns](flexible-returns.md) for finite projection and
open sinks; and [Arrays and maps](arrays-maps.md) for the subject containers'
index, length, hole, const, and metamethod rules.
