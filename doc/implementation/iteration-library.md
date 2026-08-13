# Iteration-library implementation

The user-facing contract is in the
[iteration standard-library chapter](../language/standard-library-iteration.md).
`titan.iteration` is a flat Titan source module. It needs no iterator-specific
syntax or code-generator branch: callers use the qualified
`import "titan.iteration"`, and `pairs`/`ipairs` return the four-slot generic-for
protocol already implemented by the language.

## Declared schemes and ordinary erasure

The module deliberately dogfoods the generic declaration and call machinery:

```titan
function next<K, V>(map: {K: V}, key: K?): (K?, V?)

function pairs<K, V>(map: {K: V}):
    (({K: V}, K?) -> (K?, V?), {K: V}, nil, nil)

local function array_next<T>(array: {T}, index: integer):
    (integer?, T?)

function ipairs<T>(array: {T}):
    (({T}, integer) -> (integer?, T?), {T}, integer, nil)
```

`K`, `V`, and `T` are unconstrained rigid parameters. Each therefore erases to
`value`, and optionizing `value` remains `value`. The one code-facing body of
`next` has the same ordinary representation as
`({value: value}, value) -> (value, value)`; `array_next` similarly becomes
`({value}, integer) -> (integer?, value)`. Maps and Arrays keep their existing
backing representations. There is no run-time type-argument vector, iterator
witness, or specialized body.

Explicit and inferred calls both freeze a complete surface application before
erasure. Reconstruction applies the ordinary Map-key validation, so an invalid
nil-capable `K` cannot evade Map rules through inference or an explicit list.
A complete first-class function context can likewise instantiate `next`; the
erased-core pass uses the ordinary callable-adjustment machinery when a closed
outward wrapper is required.

Inside `pairs<K,V>`, the declared result type provides the complete context for
the `next` function value. It binds that declaration to the active rigid `K,V`
application. `ipairs<T>` does the same for private `array_next<T>`. After erasure
the iterator and tuple slot have identical ordinary callable shapes, so the
canonical bodies need no hand-written adapter or `value` forwarding closure.

## `next` as an audited Lua-stack operation

Ordinary Titan has no primitive for traversing a Map's hash part. The module
therefore implements `next` through the same trusted, module-private Lua C API
boundary used by the PEG and string libraries. Its stack ledger is:

| Operation | Stack effect and obligation |
| --- | --- |
| `lua_gettop` | Save the exact entry height. |
| `lua_checkstack(L, 3)` | Reserve the Map, control key, and returned item slot before pushing. |
| `ffi.lua_pushtvalue(map)` | Push and root the existing `{K: V}` Map through its ordinary whole-slot conversion. |
| `ffi.lua_pushtvalue(key)` | Push and root the `K?` control value, including nil. |
| `lua_next(L, -2)` | Pop the control key; on success push the next key and item, or on exhaustion push nothing. It can raise for an invalid key. |
| `ffi.lua_totvalue` | Copy each successful raw `TValue` directly into a rigid `K`/`V` local. |
| deferred `lua_settop` | Restore the saved height on success, exhaustion, return, or a Lua error. |

The source contains no intermediate `value` casts or dynamic facade. Once `K`
and `V` erase to `value`, the focused second adjustment pass sees the ordinary
`Map/value <-> TValue` boundaries and selects Titan's existing whole-slot
operations around `lua_pushtvalue` and `lua_totvalue`. Raw C `TValue` already
has the required sound implicit conversions to and from `value`; the compiler
does not add a generic FFI plan, a `titan.iteration` API whitelist, or a special
coder case.

The successful `K` and `V` locals erase to traced `TValue` homes. They remain
GC-visible after the temporary Lua-stack roots are removed. No pointer into the
Map or Lua stack survives the operation. An error from `lua_next` crosses the
generated Titan error boundary, and the enclosing `defer` is the single cleanup
path rather than a guessed sequence of pops.

## Iterator tuple and option lowering

`pairs` returns `(next, map, nil, nil)`. A nil first result stops a generic
`for`; false is a valid `K` value and therefore continues. Although a successful
Map traversal always obtains a stored `V`, the direct API returns `V?` because
exhaustion supplies nil in both result slots. Generic-for can force the first
`K?` control result and a caller may request either `V?` or a nonnil `V` loop
variable through the ordinary result adjustment.

Array iteration needs no raw API. `array_next<T>` increments the integer control
value, compares it with the Array's deterministic `#` result, and returns
`(index, array[index])`. The index is deliberately first, so an inner hole
produces an ordinary iteration with a nil `T?` item instead of signaling
exhaustion. Assigning nil at the trailing position changes `#array` and therefore
the final visited index. Both public helpers return nil close slots because they
own no resource.

## Closed projections and polluted storage

Unconstrained dependent storage follows the ordinary Transient/Shallow rule.
A literal `value` transported through a rigid `V` or `T` can be written raw into
the erased Map or Array. Lua sees the same erased API and can create the same
state. Neither the container nor the iterator carries a run-time application
witness.

A closed call application reconnects the erased result with its frozen surface
type. Thus `next<string,integer>` strictly projects the successful key/item
carriers to `string?` and `integer?`, and `ipairs<integer>` does the same for its
step result. A bad string in the dependent integer slot raises the existing
`expected integer` gradual-guard error at that precise result consumption. A
copy that remains `value`, a discarded result, or another erased generic
transport need not check yet. Each later closed read checks again; projection
does not rewrite the aliased container.

First-class contextual instantiation uses the same boundary in callable form.
For example, adapting `next` to
`({string: integer}, string?) -> (string?, integer?)` may realize an ordinary
traced closure-adjustment wrapper that boxes its inputs for the canonical erased
entry and strictly projects the outputs. Such wrappers have fresh identity, as
specified for generic function values generally.
