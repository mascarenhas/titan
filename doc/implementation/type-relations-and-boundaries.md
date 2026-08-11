# Type relations and boundary plans

Titan does not use one "compatible" predicate for every place where one type
can be used as another. The checker classifies each accepted edge once, stores
the resulting plan on the checked AST or declaration metadata, and the coder
lowers that plan. This separation is important because an automatic scalar
conversion is not a gradual-consistency fact and must not be lifted through an
Array, Map, or callable merely because those types are structural. Option
composition exists only through the separately named wrap, map, and force
coercion rules; it is not generic structural lifting.

This chapter is the normative implementation matrix for type relations and
run-time boundaries. Other implementation chapters describe their local
lowering and refer here for policy.

## Relation vocabulary

`titan-compiler/types.lua` exposes the following operations:

```lua
types.normalize(typ)

types.consistent(left, right)
    --> boolean

types.coercion(source, target, policy)
    --> false | CoercionPlan

types.gradual_guard(target)
    --> false | GuardPlan

types.has_sound_gradual_guard(target)
    --> boolean

types.callable_adjustment(source_actual, target_expected, policy)
    --> false | CallablePlan

types.assignment_adjustment(source, target, policy)
    --> false | AdjustmentPlan

types.dynamic_coercion(target)
    --> false | DynamicCoercionPlan

types.written_cast(source, target, policy)
    --> false | WrittenCastPlan

types.comparable(left, right)
    --> false | ComparisonPlan
```

The retired `compatible`, `coerceable`, and `explicitly_coerceable`
interfaces are not alternate spellings for these operations. Their former
implementation mixed several different rules and let scalar conversions
escape into structural recursion.

The terms used by the compiler and manuals are:

- **consistent**: the symmetric, reflexive, deliberately non-transitive
  gradual relation;
- **coercible**: one direct automatic conversion plan exists from a source to
  a target;
- **gradual view**: one value is observed through a consistent static shape,
  with strict guards at later observations;
- **callable adjustment**: directional fixed/tail argument and result
  adaptation whose aligned components use gradual logic, not arbitrary
  coercions;
- **dynamic coercion**: the one target-directed conversion policy shared by
  written `value as/is T` and genuine Lua-to-Titan boundaries;
- **written-castable**: written syntax authorizes a conversion or checked
  reinterpretation;
- **comparable**: the symmetric equality policy; and
- **guardable/reifiable**: a later observation can establish the requested
  run-time type or raise before producing a value of that type.

Titan does not need a language-level subtyping relation. In particular,
`T -> T?` is a direct coercion, not subtyping or consistency, and it does not
license `() -> T` where `() -> T?` is expected.

## Normalization and gradual consistency

`normalize` collapses transparent Titan aliases and C typedef wrappers before
relation dispatch. It is cycle-safe: a malformed alias cycle returns no
normalized type instead of recursing indefinitely. Collapsing a transparent
name is identity normalization, not a transitive relation edge.

`consistent(A, B)` is:

- reflexive and symmetric;
- deliberately non-transitive (`integer ~ value` and `value ~ string`, but
  not `integer ~ string`);
- pointwise for Array, Map, and Option constructors;
- nominal for records, unions, and Interface descriptors;
- exact for concrete C types after typedef normalization; and
- shape-aware for Functions.

A `value` hole is consistent only with a type that has a `TValue`
representation and a sound later gradual guard. Raw C pointers are excluded:
boxing one as light userdata preserves an address but not the requested
pointee type.

The recursive implementation compares only the current normalized pair.
Array, Map, and Option descend to corresponding immediate components.
Function consistency accepts either direction of the callable shape helper,
but each aligned component is compared directly. The helper does not search
for an intermediate type and does not call `coercion`, `dynamic_coercion`, or
`written_cast`.

Titan's structural type grammar is finite. Alias declarations are collected
early to support forward references, but the resolver's pending state rejects
direct, mutual, and container-mediated cycles before a structural type can
escape. Recursive records, unions, and Interfaces instead reach a nominal
leaf. Consistency can therefore recurse directly over the syntax tree. A
completed-pair memo prevents repeated work on shared acyclic alias DAGs, while
a separate active-pair check prevents a malformed non-identity cycle
manufactured by an internal caller from serving as its own proof; neither is a
fixed-point rule of the language relation.

The C FFI separately builds recursive `Type.C*` graphs for self-referential
aggregates and callbacks. Those graphs do not make Titan structural types
recursive: consistency treats a concrete C component as an exact leaf after
typedef normalization, and cycle-safe C equality owns its internal graph.

## Direct coercion and assignment

`coercion(source, target)` returns a data-only `CoercionPlan`. Its cases
include Titan numeric conversion, named Option wrap/map/force operations,
the C/Titan numeric and address families, string/C-buffer conversion,
whole-slot C `TValue` operations, and other explicitly enumerated direct
rules. It never generically recurses through Array, Map, Function, record,
union, or Interface structure. The Option cases are named language rules with
explicit nil behavior, not a license to lift every coercion.

`assignment_adjustment(source, target)` selects exactly one operation:

```text
identity
direct_coercion(CoercionPlan)
gradual_view(project | inject | structural, GuardPlan)
callable(CallablePlan)
rejected
```

Function assignment is directional even though `consistent` is symmetric.
`callable_adjustment(source_actual, target_expected)` records aligned fixed
arguments/results, ignored surplus, missing-argument nil fill, input-tail
transfer, flexible-result projection, hidden results, end-of-tail actions, and
the named missing-result action `nil_fill_result`. Every ordinary aligned
component may be identical, a gradual injection/projection/view, or another
callable adjustment. Numeric conversion, `T`/`T?` conversion, C conversion, and
record/union-to-Interface wrapper construction are rejected as callable
component matches.

`nil_fill_result` is emitted only when an expected fixed result has neither a
fixed nor flexible source and its target passes `accepts_missing_nil` (Nil,
Value, Option, Titan Pointer, or CPointer). It records the target index/type and
has no source component plan. Required scalar and nominal results reject; a
source-flex action takes precedence. Shape-specific nil and flexible-result
absence remain named callable actions rather than relation leaves. Thus a
flexible actual tail can supply a finite optional projection and a truly absent
result can be filled under the narrow policy, but neither makes an ordinary
fixed result `T` consistent with `T?`. The complete freezing/lowering contract
is [Closure adjustment wrappers](closure-adjustment-wrappers.md).

## Strict gradual guards

`gradual_guard(T)` describes the strict observation protocol for `T`. Scalar,
nominal, and container-kind observations check immediately and either produce
the required representation or raise a normal type error. Function values are
the deliberate deferred case: the boxed carrier is preserved and every call
performs exact/branded/non-Titan dispatch, so a non-callable value raises
before a function operation can use it. A guard never performs automatic
numeric conversion, truthiness, Option introduction/force, or pointer
conversion. The strict rules are therefore:

| Target | Strict observation |
| --- | --- |
| `integer` | integer tag only |
| `float` | float tag only |
| `boolean` | boolean tag only |
| `string` | string tag only |
| Array | canonical proxy/shared-metatable check; contents deferred |
| Map | table check; keys and values deferred |
| record/union/Interface | exact nominal metatable |
| Function | boxed value; exact/strict call dispatch verifies use |
| `T?` | nil, or the recursive strict guard for `T` |
| C integer/float | their explicit tagged/range policy |
| owned C userdata | exact owned metatable |
| C `TValue` | whole-slot carrier |
| raw C pointer | unavailable |

Every typed Titan Array and Map read uses this strict policy. Map reads do so
regardless of whether the slot was written by Titan or Lua; a raw Lua table
has no interception or provenance bit from which the compiler could select a
different policy. Callable adjustment components also use strict guards: a realized wrapper
executes them in its target-native adapter, while a branded exact-tag mismatch
executes them through the existing strict generic entry/result path.

`has_tvalue_representation(T)` asks only whether `T` can occupy a boxed slot.
`has_sound_gradual_guard(T)` asks the stronger question above and recurses
through compound types. Boxability must never be used as proof of
reifiability.

## Dynamic coercion

`dynamic_coercion(T)` is broader than a gradual guard. It is authorized only
when the programmer wrote `value as/is T`, or when a value genuinely crosses
from Lua into a typed Titan sink. Its native-result, boxed-store, and
non-raising predicate lowerings are generated from the same plan.

The initial target matrix is:

| Target | Dynamic operation |
| --- | --- |
| `integer` | integer, or exactly integral in-range float, producing integer |
| `float` | float or integer, producing float |
| `boolean` | Lua truthiness |
| `nil` | exact nil |
| `string` | exact string |
| `value` / C `TValue` | whole-slot copy |
| Array | validate only the canonical outer Array representation |
| Map | validate only the outer table representation |
| Function | preserve the boxed value; invocation decides callability |
| record/union/Interface | exact nominal metatable; an Interface requires an existing wrapper |
| `T?` | preserve nil; otherwise recursively apply the dynamic plan for `T` |
| C integer/float | explicit numeric/tag/range policy |
| owned C userdata | exact owned metatable |
| raw C pointer | unavailable |

Option recursion is intentional. In particular, a present
`value as boolean?` uses truthiness just like `value as boolean`; nil remains
nil. The corresponding `is` predicate reports whether that same conversion
would succeed without returning the converted value. It is not a separate
tag-only implementation.

The Interface dynamic case accepts only an already constructed wrapper
with the exact target Interface metatable (or nil for an optional target).
It never discovers that a bare record/union implements the Interface and
never constructs a wrapper after the concrete static owner and method mapping
have been erased. Concrete record/union-to-Interface conversion remains one
checker-planned direct outer coercion; it is neither consistency nor
structural subtyping. The complete matcher, wrapper plan, and adjustment
boundary are documented in [Interfaces](interfaces.md).

## Checked C scalar conversions

C integer and floating descriptors carry checker-local traits from the
selected C target profile. The profile, not the host running the compiler,
defines integer signedness/precision/ranges, floating radix/mantissa/range,
and the `lua_Integer` and `lua_Number` carrier types. These traits guide
lowering but are not serialized type identity.

Foreign variables, call results, fields, indexes, macros, and C-expression
results remain raw values of their exact C type until a checker-owned plan
requests another numeric type or a boxed slot. All potentially partial
crossings share one predicate/cast implementation:

- C integer to Titan `integer` and C numeric boxing validate the Lua carrier
  interval before casting or mutating a slot;
- Titan `integer` to a C integer validates the destination interval, with
  `_Bool` restricted to 0 and 1;
- a strict boxed C-integer projection accepts only an integer tag, while its
  dynamic counterpart also accepts an exactly integral float that first fits
  `lua_Integer`; both then validate the C target interval;
- a strict boxed C-float projection accepts only a float tag, while its
  dynamic counterpart accepts either numeric tag; both apply the same target
  range rule;
- same-or-wider floating conversions preserve finite values, NaNs, and
  infinities. Floating narrowing rejects non-finite or out-of-range values
  while allowing ordinary rounding and underflow;
- floating-to-integer conversion rejects non-finite or out-of-range values,
  then truncates toward zero; and
- integer-to-floating conversion checks the target range when the profile
  cannot prove containment.

Written C-integer-to-C-integer casts deliberately keep ordinary C conversion
semantics. Checker-selected integer promotions and usual arithmetic
conversions inside a C expression do so as well. This exception does not
extend to integer-to-floating operator conversion, which is range-checked
when containment is not statically proven.

`as` and `is` consume the same `CoercionPlan` or explicit-conversion plan.
The cast commits only after its predicate succeeds; the test returns that
predicate without converting or raising. Dynamic and strict boxed lowering,
Option recursion, and `TValue` stores reuse the same acceptance logic so a
successful `is` cannot precede a failing corresponding cast.

`written_cast(source, target)` selects identity, direct coercion, dynamic
coercion from `value`, gradual/callable view, or one separately enumerated
explicit conversion. Under the raw-pointer policy, `value as *C` is the one
written unsafe reinterpretation: ordinary pointers check the broad
lightuserdata/nil category, while Lua-internal `Udata *` checks
full-userdata/nil. Neither proves an ordinary pointee type. No implicit
assignment or compound gradual path can contain that operation.

Two C operations are deliberately not complete type-only
`written_cast` results. Taking a mutable address requires an addressable local
or formal, and an unrelated object-pointer reinterpretation requires the
active C toolchain's successful directional cast check.
`check_explicit_cast_relation` finalizes those cases only after proving the
expression shape or receiving the probe key. The resulting
`WrittenCastPlan` carries `mutable_c_address` or the exact probe-bearing
conversion; candidate-only plans are never coder authority.

## Normative boundary matrix

This table controls which of the two run-time policies a lowering may use:

| Site | Checker plan | Run-time policy |
| --- | --- | --- |
| exact Titan assignment/call | identity | preserve the source value; an exact call uses its native entry with no boundary check |
| direct Titan scalar/Option/C assignment | `CoercionPlan` | exactly that conversion |
| finite non-exact Function `A -> B` assignment or written callable `as` | raw `CallablePlan` plus frozen `CallableAdapterPlan` | evaluate once; exact branded A with upvalue room becomes a fresh B wrapper/native adapter, otherwise preserve the value for strict/non-Titan generic fallback |
| implicit/dynamic `value -> T` assignment | gradual or dynamic projection | strict/dynamic target rule; a Function target preserves the boxed carrier and never realizes a statically known wrapper |
| Array or Map read yielding `T?` | `GuardPlan(T?)`, or static rejection | strict guard, recursively through Option |
| callable arguments/results in a realized wrapper | frozen component actions and root/rebase ledger | target-native adapter executes strict actions, including nested conditional wrappers and `nil_fill_result` |
| branded exact-tag-mismatch callable arguments/results | declaration/relay-attached argument/vararg guards and call-attached result guards | strict generic path; the raw `CallablePlan` establishes that the view is admissible |
| written `value as T` | `WrittenCastPlan(dynamic)` | dynamic coercion or normal error |
| written `value is T` | same dynamic plan | non-raising dynamic predicate |
| Lua call into a Titan function | per-formal `DynamicCoercionPlan` | dynamic coercion |
| Lua module/record field write | per-slot `DynamicCoercionPlan` | dynamic coercion |
| non-nil Lua Array write | construction-selected writer plan | dynamic coercion before mutation |
| nil Lua Array write | Array deletion rule | delete/hole; bypass element conversion |
| result from a non-Titan Lua callable | per-result `DynamicCoercionPlan` | dynamic coercion |
| raw Lua Map mutation, then Titan read | no write plan is available | the later strict Map-value guard |

Thus an integral float can enter an integer formal from Lua, be stored through
an integer Array's Lua writer, or succeed under written `value as integer`.
The same float stored in an Array or Map through a Titan `{value}` view fails a
later strict integer read. Likewise a truthy nonboolean becomes `true` at the
written/Lua boundary but fails an implicit gradual projection to boolean.

## Checker-owned plans

`checker.lua` elaborates accepted edges and retains the decision:

- fixed casts use `_adjustment`; in particular, every finite non-exact
  callable edge is an `Ast.ExpCast` whose child remains A and whose cast type is
  B, with the original raw plan plus its frozen callable-adapter annotation;
- same-representation Array/Map structural views use
  `_assignment_adjustment`; callable plans no longer use this exception;
- `_open_results`, `_open_dots`, `_open_args`, and positional-constructor
  adjustment records carry their element `adjustment`; the checker freezes and
  attaches callable-element adapters at the owning source location, and the
  coder consumes and registers those already frozen graphs;
- every typed Array/Map bracket node carries `_read_guard`, including the
  recursive outer Option guard produced by ordinary indexing; if no sound
  guard exists, the checker rejects the read rather than storing an unavailable
  plan for code generation;
- written `as`/`is` nodes carry `_written_cast`;
- equality nodes carry `_comparison`;
- strict function formals, variadic elements, fixed results, and open results
  carry their parallel GuardPlan annotations;
- Lua function formals, variadic elements, module/record write slots, Array
  constructors, and non-Titan Lua-callable results carry their target
  `DynamicCoercionPlan` (or an explicit `false` when unavailable); and
- each Array constructor records its final context-adjusted element type and
  writer plan.

`trycoerce` returns the exact decision it obtained for the sink, and
`checkmatch` consumes that same object; it never calls a type relation. A
representation-changing decision and every finite non-exact callable decision
must already have produced an annotated cast. Only a same-representation
Array/Map structural decision remains attached to the source expression.
Callable casts may allocate a wrapper and their frozen adapters perform
component observations; an ineligible run-time carrier is nevertheless
preserved for generic fallback. An Option has no separate mutable backing:
establishing
`A?` as a gradual `B?` view immediately applies the recursive strict guard to
its present payload (nil passes unchanged). This prevents a later identity
Option force or map from forgetting which base tag was actually stored. A
rejected checked-C conversion can suppress the
generic mismatch only after its more precise diagnostic has been emitted.

Open consumers preserve the same plan instead of asking the coder to infer an
element cast from unequal types. This covers flexible results, forwarded
`...`, and positional Array/integer-Map construction. A deferred positional
constructor does not classify a provisional open edge: after inference or
context chooses the final element type, it calls `assignment_adjustment`
exactly once and stores that same plan on the sink and producer annotation.

The coder validates the complete stored plan kind, operation, normalized
source/target, action lists, and recursive children before lowering. This
includes Adjustment, Callable, WrittenCast, Guard, DynamicCoercion, Coercion,
and Comparison plans. A root `false` Guard or DynamicCoercion annotation is
the deliberate unavailable-policy sentinel: its lowering raises a normal
run-time type error. Missing annotations, `false` in every other plan family,
an unavailable recursive child, and unknown or mismatched operations are
compiler-integrity errors. Representation-specific emitters are not
authorization oracles: they run only after this validation, must not call a
semantic relation, and must not synthesize an unannotated semantic
`Ast.ExpCast`.

Written gradual and callable casts use the same plan-consuming adjustment
lowering as implicit sinks. Array and Map views preserve their carrier; a
written non-exact callable `as` conditionally realizes a wrapper, while its
`is` twin remains allocation-free. An Option view performs its immediate strict
present-payload observation. The `is` lowering consumes the same
`WrittenCastPlan` as `as`,
including partial float-to-integer and recursively composed Option
coercions; it produces the non-raising acceptance predicate rather than
assuming every statically admitted cast is total.

## Comparison

`comparable(left, right)` is symmetric. It accepts identity, gradual
consistency, mixed Titan integer/float equality, and recursive Option
comparison. Before classification, checker equality lifting turns Nil opposite
an Option into that Option through the named `option_nil` coercion, so the
classifier sees two same-representation option operands. When exactly one
comparable operand is `value`, the same plan also carries the required gradual
injection so both operands reach the boxed
raw-equality representation. The checker classifies the original pair before
applying that recorded injection. Ordering retains its separate numeric/string
rules. Equality does not reuse directional callable assignment and therefore
cannot depend on operand order. Code generation validates the stored
`ComparisonPlan` (and any recorded one-sided injection) before choosing raw,
numeric, or Option comparison lowering; it does not rediscover comparability
from the adjusted operand tags.

## Failure contract and FFI boundary

A failing guard, coercion, or written conversion is a normal Titan/Lua error.
A checked program must not reach an unknown plan, reinterpret one native
storage class as another, or manufacture a differently typed raw address
through an implicit gradual path.

Ordinary raw C pointers are boxed as untyped light userdata, so the runtime
cannot recover pointee identity or qualifiers. Direct statically typed C
pointer conversions remain `CoercionPlan`s. A written `value as` raw-pointer
cast is explicitly unsafe; raw-pointer leaves are excluded from `value`
consistency and from Array/Map/Option/Function gradual plans. Owned C userdata
remains dynamically guardable because its metatable preserves nominal
identity.

Privileged C code and Lua's debug library can mutate private user values,
upvalues, and metatables. Such code is outside Titan's checked-program
contract; the runtime validates ordinary boundary carriers but does not
promise to repair deliberate invariant corruption.
