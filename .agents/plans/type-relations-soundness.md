# Type-relation consistency audit and repair plan

Status: **second audit and implementation complete; separated relation APIs,
ABI-0.20 Array/function runtime layouts, focused regressions, both manuals,
repository instructions, independent reviews, the final requirement audit,
isolated full-suite/coverage/library validation, and the local commit are
complete. Draft PR #42 is published. Its first exact-head Linux run exposed
two covered-path performance regressions: exact function-value calls consulted
the reverse tag registry, and repeated C profile validation rebuilt exact
decimal powers. The local follow-up restores the static-tag likely fast path,
uses one fixed opaque closure brand for non-exact Titan calls, memoizes only a
bounded set of modest pure powers while retaining full profile validation, and
simplifies consistency to direct structural recursion with completed-pair
memoization. Both local covered shards, their combined 89.74% report, focused
closure/stack regressions, and independent follow-up reviews are green. The
follow-up commit/push and a green exact-head Linux/Codecov rerun remain.
Interface-specific final-release gates stay with Interfaces v1.**

This replaces the first audit of the same name. The first pass found several
real compiler failures, but its model was still too close to the current
implementation: it treated directional callable assignment as part of
`types.compatible`, proposed subtyping and consistent subtyping relations that
Titan does not need, and accepted too quickly the claim that every mutable
container mismatch is paid for by an adequate read check.

The maintainer's model for this pass is authoritative:

- gradual consistency is reflexive, symmetric, and deliberately
  non-transitive;
- `value` is Titan's dynamic type;
- consistency descends pointwise through structural types, like equality with
  `value` holes;
- automatic coercion is a different relation;
- in particular, `T -> T?` is an automatic coercion, not consistency, and it
  must not make `() -> T` usable as `() -> T?`;
- Titan does not currently need a language-level subtyping relation;
- every typed Titan Array or Map read uses strict tag guards; Map reads do so
  regardless of whether the stored value originated in Titan or Lua, while
  genuine Lua Array writes retain dynamic coercion through a
  construction-module writer closure carried by the canonical proxy;
- Array proxies keep one shared metatable for constant-time kind checks; the
  writer is a second traced user value, not a globally interned runtime type
  tag or a heap invariant;
- written `value as/is T` and genuine Lua-to-Titan boundaries consume one
  canonical target-directed dynamic-coercion matrix. This is broader than a
  strict gradual guard, but it remains unavailable to ordinary consistency or
  structural lifting; an Interface target accepts only an existing exact
  wrapper because v1 cannot construct one after the concrete type is erased;
- Titan function values have one native entry and two Lua-stack entries: the
  closure's ordinary `f` remains the coercive genuine-Lua entry, while a
  strict Titan-generic light C function in the closure's final upvalue handles
  non-exact Titan calls; exact tags still use the native pointer in upvalue 2;
- callable arity/tail adjustment may be non-structural, but its calls back
  into consistency must compare ordinary aligned component pairs directly;
  synthesized nil/flexible projections remain named shape rules rather than
  non-structural self-calls through an intermediate type, and the helper must
  not consult the general coercion relation; and
- transparent aliases/C typedefs may be normalized to their underlying type
  before comparison. That is identity normalization, not transitivity.

Implementation spans the separated relation and plan APIs in
`titan-compiler/types.lua`, checker elaboration in
`titan-compiler/checker.lua`, plan-consuming guards/open runs/function entries
in `titan-compiler/coder.lua`, the two-user-value Array proxy in
`titan-runtime/titan.c` and `titan-runtime/titan.h`, standalone argument Arrays
in `titan-compiler/driver.lua`, and the coordinated ABI-0.20
driver/installer/CI fixtures. Focused relation, boundary-parity, compiled-DSO,
and selected-archive regressions pass. Separate language-manual,
implementation-manual, repository-instruction, code, and completion reviews
are clean. Isolated full, coverage, and library validation is green and the
reviewed base tree is committed and published as draft PR #42. The first
exact-head Linux run passed the producer, sanitizer, and library consumer but
the heavy covered consumer timed out before its upload. The focused follow-up
above restores both hot paths; the exact local heavy and core coverage shards
are green, and an exact-head Linux/Codecov rerun remains.

## 1. Correctness target

There are two separate targets.

### 1.1 Relation correctness

`consistent(A, B)` must mean gradual consistency and nothing else. It must
not become a general "can be used as" predicate.

For every accepted use of a source value in a target context, the checker must
record which of these happened:

1. exact identity;
2. a direct automatic coercion;
3. a gradual view whose observations are guarded;
4. callable shape adjustment whose aligned components are gradually
   consistent; or
5. a target-directed dynamic coercion authorized either by written
   `value as/is T` or by a genuine Lua-to-Titan boundary; or
6. another separately authorized written cast.

No result in one category may be treated as evidence for another category.

### 1.2 Execution correctness

A checked program may encounter a failing gradual guard or a partial coercion
and raise a normal Titan/Lua error. It must not:

- abort in the compiler on an unhandled checked AST/type;
- reinterpret one native Titan storage class as another;
- omit a guard promised by a gradual view;
- replace a strict Titan gradual observation with a genuine-Lua coercion;
- vary a typed Map read according to guessed Lua/Titan write provenance;
- store a non-nil genuine-Lua Array write before its construction-policy
  conversion succeeds;
- synthesize a conversion that the checker did not select; or
- reach invalid C behavior solely because an implicit Titan relation erased
  information that the later operation needed.

Raw foreign addresses need an explicit boundary statement. Titan cannot prove
the provenance of an arbitrary address supplied by C or Lua. It can, however,
avoid manufacturing a differently typed address through an implicit gradual
path. Section 8 makes that distinction actionable.

Likewise, a program that uses the debug API or privileged C code to mutate an
Array proxy's private metatable/user values, its backing key 0, or other
runtime invariants is outside this checked-program correctness target. The
debug library is forbidden for untrusted code; the runtime need not add writer
identity checks or repair guarantees for deliberate invariant corruption.

## 2. Executive findings

The first audit's broad positive conclusion is not justified.

### 2.1 `types.compatible` is not gradual consistency

The central defect is category pollution: operations that should be direct
automatic coercions were added as leaves of the relation being used for
gradual consistency. Array/Map recursion and callable alignment then did what
their definitions naturally say and lifted those polluted leaves into
compound types. The repair is therefore to separate the leaf relations, not
to remove legitimate structural recursion or to add a transitive-closure
guard.

The actual function contains all of the following:

- gradual `value` holes;
- Array/Map structural recursion;
- nominal identity;
- Titan/C numeric conversions;
- truthiness;
- nil/pointer conversion;
- C address-taking, array decay, owner borrowing, pointer qualifier, and
  pointer-category conversions;
- string/C-buffer conversion;
- C `TValue`/boxed-C conversion;
- every written-only `explicitly_coerceable` edge; and
- directional callable assignment, including ordinary component coercions.

Only the first three groups, transparent normalization, and a carefully
defined symmetric callable-consistency rule belong in gradual consistency.

### 2.2 There is no explicit transitive-closure algorithm

The implementation never searches for an intermediate type `B` to prove
`compatible(A, C)`. Its direct recursive calls are:

- transparent C typedef unwrapping;
- legacy scalar typedef unwrapping;
- Array element descent;
- Map key/value descent; and
- callable component descent after shape alignment.

The alias cases are normalization. Array/Map are structural. Callable
alignment is permitted in principle, provided each aligned component is
compared directly.

The defect is instead that several non-consistency edges are present at the
leaves and are therefore lifted through Array, Map, and Function. Programs can
then compose two accepted views even when the direct relation is false.

### 2.3 A confirmed Array bridge uses no `value`

This checks today:

```titan
local ffi = foreign import "titan/ffi.h"

function bridge(): integer
  local source: {float} = {2.0}
  local middle: {ffi.titan_ffi_double} = source
  local final: {integer} = middle
  return final[1]
end
```

Observed:

- checker errors: `0`;
- generated module runs; and
- `bridge()` returns integer `2`.

The direct assignment is rejected:

```titan
function direct(source: {float}): {integer}
  local final: {integer} = source
  return final
end
```

The path exists because:

```text
compatible(C-double, float)
compatible(integer, C-double)
not compatible(integer, float)
```

with the current expected/found argument convention. Array recursion lifts
both first-order conversion edges without inserting an element conversion.
The final integer read performs the conversion.

This is precisely the unwanted composition that a pure gradual-consistency
relation must prevent. A `value` bridge may intentionally connect unrelated
types and defer a guard; a C numeric conversion must not masquerade as such a
bridge.

The same construction applies to Map values.

### 2.4 Callable slots recursively lift every coercion

`slot_compatible(target, source)` currently is:

```lua
types.compatible(target, source)
or types.coerceable(source, target)
```

Consequently all of these check:

```titan
function integer_result(): integer return 1 end
function float_result(): float return 1.5 end
function float_input(x: float) end

function examples()
  local optional_result: () -> integer? = integer_result
  local narrowed_result: () -> integer = float_result
  local converted_input: (integer) -> () = float_input
end
```

The first is the maintainer's explicit negative example: `integer -> integer?`
is a coercion and must not lift through a function result. The numeric input
and result cases are the same category error.

The current tests require this old behavior at
`spec/types_spec.lua:265-276` and `339-346`; those assertions need to be
reversed or moved to direct-call/coercion tests.

### 2.5 Coercion-lifted function relations compose

This direct assignment is rejected:

```titan
function none(): nil return nil end

function rejected(): integer
  local f: () -> integer = none
  return f()
end
```

This two-step version checks:

```titan
function none(): nil return nil end

function through(): integer
  local optional: () -> integer? = none
  local definite: () -> integer = optional
  return definite()
end
```

Observed:

- checker errors: `0`; and
- `through()` raises a normal `expected integer` error.

The same chain lifts again through Array:

```titan
function none(): nil return nil end

function through_array(): integer
  local first: {() -> nil} = {none}
  local middle: {() -> integer?} = first
  local final: {() -> integer} = middle
  return final[1]()
end
```

This also checks and raises cleanly at the call.

The clean error means these examples do not corrupt a pure Titan
representation. They still prove that the current relation admits an
unintended path with no dynamic `value`, solely because Option coercions were
recursively lifted into Function and then Array.

### 2.6 Pure Titan Array/Map observations tested so far fail cleanly

The second pass exercised:

- `{integer} -> {value}`, mutation through the `value` view, then an integer
  read;
- `{value} -> {integer}` with a wrong stored element;
- nested `{{integer}} <-> {{value}}`;
- arrays of compatible function values, including replacement through the
  alternate view; and
- the corresponding Map value paths.

Representative witness:

```titan
function probe(): integer
  local original: {integer} = {17}
  local dynamic: {value} = original
  dynamic[1] = "wrong"
  return original[1]
end
```

It compiles and raises a normal `expected integer` error at the read.

This witness does not exercise the planned Lua writer. Titan indexed writes
operate directly on the backing under the static element type of the current
view. That is why the later strict read, rather than the write, detects the
alternate-view mismatch.

The nested and function-valued cases did the same. Exact function tags alone
take the native path; a differently typed function value takes the checked
generic path.

This is positive evidence for the ordinary Titan value domain. It is not a
proof for every element type, because Sections 2.7 and 2.9 expose holes in the
guard inventory.

### 2.7 Strict Titan observations and shared dynamic coercions need different policies

Gradual observation and ordinary Lua/coercion boundaries share
`checkandget`/`checkandset`.

Confirmed behavior:

```titan
function number_view(): integer
  local dynamic: {value} = {2.0}
  local typed: {integer} = dynamic
  return typed[1]
end
```

returns integer `2`; it does not reject the float tag.

Likewise:

```titan
function actual(): value return "nonempty" end

function through(): boolean
  local f: () -> boolean = actual
  return f()
end
```

returns `true`; the generic result boundary applies truthiness.

Those outcomes are valid for an explicitly requested `value as T` dynamic
coercion and for the corresponding genuine-Lua boundary. They are defects when
reached merely by observing a gradual container/callable view. Under the
maintainer's actual-type-on-read rule, container/callable consistency cannot
reuse those coercive helpers. The coder needs a separate strict gradual guard:

- integer accepts only an integer tag;
- float accepts only a float tag;
- boolean accepts only a boolean tag; and
- the existing structural/nominal categories keep their exact runtime tests.

The strict rule applies to Titan observations through a gradual view and to
every typed Array/Map read from their dynamically mutable storage. It does
**not** make explicit `value as T` or the genuine Lua boundary strict. Those
two contexts deliberately request the same target-directed dynamic coercion.
A value assigned by Lua to a function formal, module variable, record field,
or Array element remains eligible for it, and `value as T` must accept and
convert exactly the same dynamic values. Generate all of these uses from one
normative matrix even though `checkandget` returns a native value and
`checkandset` writes a boxed slot. The current helpers already drift: integer
handling has been made broadly coercive, while boolean function arguments use
truthiness and boolean record/module writes require an actual boolean tag.

This equivalence is contextual authorization, not a new implicit relation.
Ordinary Titan assignment from `value`, Array/Map pointwise consistency, and
aligned Function components still use gradual views and strict observations;
they cannot call the dynamic-coercion matrix. Conversely, a written
`value as T` applies the broader plan immediately. For example, an integral
float may succeed as `value as integer` while the same `TValue` stored in an
Array or Map viewed as integer raises on a typed Titan read.

Arrays need enough construction-time behavior to apply that loose policy on a
Lua write without weakening Titan reads. Keep the one shared Array proxy
metatable and extend the canonical proxy from one to two traced user values:

Today `titan_array_lua_newindex` intercepts the write but passes stack slot 3
straight to `titan_array_set_stack`; it has no element policy and therefore
stores the incoming non-nil Lua value verbatim. The repaired path replaces
that store with the carried writer conversion.

```text
proxy->metatable = shared Array metatable
proxy->uv[0]     = backing Table             (Lua user value 1)
proxy->uv[1]     = module-local writer CClosure for element type S
backing[0]       = proxy
```

Each module generates and caches one writer closure in a private module slot
for every Array element type for which that module emits a constructor. Array
construction copies that closure into the proxy. A different module may
generate a different, extensionally equivalent closure for the same
structural Array type. The closure is behavior carried by the object, not a
globally interned type tag: there is no registry key, "first one wins"
protocol, or cross-module closure-identity requirement.

The shared `__newindex` validates the ordinary proxy/backing invariant, loads
the receiver's writer closure, and delegates the non-nil conversion/store.
Nil remains the common Array deletion operation. The writer uses the canonical
dynamic-coercion matrix for `S` also used by `value as S` and every other
genuine Lua sink, completes conversion before mutation, and may capture its
generating module's `_mod` for nominal/C conversions.

The writer is not a heap invariant for Titan code. A Titan write through an
alternate `{value}` view still writes according to that static view, and a
later stricter read through `{integer}` may raise. The closure records only
which automatic conversions genuine Lua writes use.

All Titan Array-kind checks retain direct equality with the one shared proxy
metatable. They do not inspect `uv[1]`. This is especially important for
`{{value}}`: reading every inner Array must not chase a per-type metatable or
writer marker. Nested raw backings recover their canonical proxy and perform
the same shared-metatable pointer test.

After the shared callback loads the carried writer from `proxy->uv[1]`, no
second writer-identity proof is required. Ordinary Lua cannot mutate user
values; code using the debug API accepts responsibility for preserving Titan
invariants, and the debug library is not available to untrusted code.

Functions need the same semantic split without changing their one public
closure identity. Today a non-exact call in `codevaluecall` pushes the original
Titan `CClosure`; Lua therefore invokes its coercive `genluaentry`, exactly as
if Lua had made the call. Replace that with three entry roles:

```text
native entry:
  static/direct calls and exact-tag first-class calls

coercive Lua-stack entry (CClosure.f):
  genuine calls from Lua

strict Titan-generic entry (light C function in final upvalue):
  non-exact calls from Titan
```

The repaired Titan closure header is:

```text
CClosure.f    = coercive genuine-Lua entry
upvalue[0]    = owning module Udata
upvalue[1]    = canonical function-type tag
upvalue[2]    = native entry pointer
upvalue[3]    = fixed opaque Titan-function brand
upvalue[4+i]  = captured value i
upvalue[last] = strict Titan-generic lua_CFunction as an LCF TValue
```

For a non-exact branded Titan closure, `codevaluecall` pushes the stored LCF as
the VM callee, then the original closure as one hidden argument, then the
ordinary arguments. `luaD_callnoyield` supplies a real `CallInfo`, so the
strict entry retains the existing finite/flexible result-request machinery.
The entry excludes the hidden argument from arity adjustment, recovers `_fn`
from it and `_mod` from `_fn->upvalue[0]`, applies strict gradual guards for
the runtime callee's declared formals, and calls the native entry with the
original closure so captures remain available. It boxes results under the
runtime callee's declared types; the caller then applies strict guards for its
static result view.

The strict LCF is deliberately a trailer rather than another fixed header
slot. The brand intentionally expands the fixed header and shifts lambda
captures and bound receivers by one slot: a top-level closure has five
upvalues, a lambda has four header slots plus captures plus the trailer, and a
bound method keeps its receiver at upvalue 4 and adds the trailer after it.

An exact static tag match is the likely native fast path and trusts the private
Titan header without a registry lookup, under the same debug/C-API contract as
the upvalues themselves. Both the exact and non-exact predicates first require
the five-upvalue minimum. The exact branch compares the raw pointer bits in
upvalue 1 with the canonical static tag. After that comparison fails, the
non-exact branch compares only the raw pointer bits in fixed upvalue 3 with
the random 64-bit ABI sentinel `TITAN_FUNCTION_CLOSURE_BRAND`; there is no
registry lookup or other `ttis*` shape check. Requiring the correct count,
slot, and sentinel makes accidental recognition by a foreign C closure
astronomically unlikely. A Lua closure, Lua light C function, foreign C
closure, or `__call` object without the sentinel stays on the ordinary
generic Lua-call path. Its results cross a genuine Lua-to-Titan boundary and
therefore use the target result's `DynamicCoercionPlan`; only a branded
non-exact Titan closure's results use strict gradual guards.

Generate the coercive and strict stack entries from one shared
arity/tail/result/error-frame template parameterized by boundary policy,
argument-base offset, and `_fn` source. Do not build a companion full closure:
that would allocate an unnecessary object and create an avoidable
closure-to-adapter-to-closure ownership cycle. A pointer bundle behind
upvalue 2 is also not the initial design; it would add indirection to every
exact call and require safe validation before dereferencing a foreign pointer.

Debug upvalue access or C-API mutation of this private closure header is
outside the untrusted-code contract, like Array/userdata invariant mutation.
The strict entry should nevertheless reject a malformed hidden carrier before
reading it as a Titan closure. No design may trust a raw pointer slot merely
because an unbranded foreign closure has the same number of upvalues.

The repair therefore preserves legitimately enumerated direct coercions and
the broader numeric/truthiness `DynamicCoercionPlan` used by written
`value as T` and genuine-Lua sites, while preventing either from being lifted
silently through Array, Map, or Function. Section 5 specifies the complete
Array operation split.

### 2.8 Checked open runs still abort code generation

Both programs below have zero checker errors and fail code generation with:

```text
invalid node tag Ast.ExpCast
```

Flexible-result case:

```titan
function produce(): (...: {value})
  return {1}
end

function consume(): {{integer}}
  return {produce()}
end
```

Variadic-forwarding case:

```titan
function sink(...: {{integer}})
end

function forward(...: {{value}})
  sink(...)
end
```

The checker admits a compatible whole Array element. Three coder paths treat
every unequal open element pair as a scalar cast:

- `coder.lua:4243-4279`;
- `coder.lua:4459-4489`; and
- `coder.lua:7249-7265`.

This is not a type-theory subtlety. The checker discarded the reason for
acceptance, and the coder guessed the wrong operation.

### 2.9 Ordinary C-valued container reads can abort code generation

This simpler program also has zero checker errors:

```titan
local ffi = foreign import "titan/ffi.h"

function first(): integer
  local xs: {ffi.titan_ffi_int} = {
    1 as ffi.titan_ffi_int
  }
  return xs[1]
end
```

Code generation fails with:

```text
invalid type titan_ffi_int
```

The path is:

1. Array indexing produces `Option(CInteger)`;
2. `checkandgetmixed` handles the Option;
3. its present branch calls `checkandsetmixed(CInteger, ...)`;
4. that falls through to `checkandset`; and
5. `checkandset` has no C integer/float/pointer/raw-`TValue` arms and errors at
   `coder.lua:876`.

Map values have the same read helper. The earlier claim that all Array/Map
reads guard all admitted element types was therefore too broad.

This must be fixed independently of relation cleanup, and it motivates a
mechanical completeness invariant:

> Every type accepted by `has_tvalue_representation` for Array/Map storage has
> a store operation, a strict gradual guard, an Option-present guard, a
> genuine-Lua boundary conversion, an Array-writer lowering when used as an
> Array element type, and tests for each applicable channel.

### 2.10 Raw C pointers are not dynamically reifiable today

Ordinary C pointers are boxed as untyped lightuserdata. Recovering a requested
C pointer checks only "lightuserdata or nil", then casts the address to the
requested C pointer type. No pointee identity or qualifiers remain.

Therefore this gradual path cannot enforce an actual C pointer type:

```titan
local original: {*ffi.some_type} = ...
local dynamic: {value} = original
dynamic[1] = a_pointer_of_another_C_type
local recovered: *ffi.some_type = original[1]
```

The last read sees lightuserdata and succeeds. A later foreign operation that
relies on `*ffi.some_type` can operate on storage of another C type.

This is not fixed by removing C conversion edges from `consistent`: the
`value` hole alone is enough to erase raw-pointer type identity. Direct
`value -> C pointer` has the same limitation.

There are only two honest policies:

1. declare raw C address provenance outside Titan's sound gradual guarantee,
   require a written unsafe cast for `value -> raw C pointer`, and exclude raw
   pointer leaves from structural gradual views; or
2. replace lightuserdata crossing with a typed pointer box carrying enough
   identity/qualification metadata for a guard.

For an initial release, this plan recommends policy 1. Owned C userdata can
remain dynamically reifiable because its metatable retains nominal identity.

### 2.11 Other confirmed defects from the first pass remain

- Equality can be operand-order dependent because it calls directional
  callable compatibility once.
- A written-only C edge can leak into callable assignment through
  `explicitly_coerceable` inside `compatible`.
- `T? -> C TValue` needs a whole-slot plan so nil is preserved rather than
  forced before boxing.

These remain in the plan, but they are no longer presented as the main
soundness result.

## 3. Audit of every `compatible` branch

The repaired implementation should make this classification visible in code,
not just in this document.

| Current branch | Actual meaning | Destination |
|---|---|---|
| exact `equals` | identity | `consistent`, identity plan |
| `CTypedef`/legacy `Typedef` recursion | transparent normalization | normalize before all relations |
| C integer ↔ Titan integer | automatic conversion | `coercion` |
| C float ↔ Titan float | automatic conversion | `coercion` |
| Titan integer -> C float | automatic conversion | `coercion` |
| C pointer -> boolean | truthiness conversion | `coercion` |
| nil ↔ C/Titan pointer | polluted symmetric nullability; only nil -> pointer is an implicit null conversion | forward edge to `coercion`; reject reverse |
| C local address/array decay/owner borrow | address conversion with lifetime plan | `coercion` |
| C pointer qualifier/category rules | C conversion | `coercion` or written cast |
| string -> C char/void pointer | borrowed-buffer conversion | `coercion` |
| C value ↔ `value` | boxing/projection | `coercion`; guardability policy |
| C value ↔ raw `TValue` | whole-slot copy/conversion | `coercion` |
| `explicitly_coerceable` | written-only permission | `written_cast` only |
| `value` hole | gradual consistency | `consistent`; operational plan still required |
| Array/Array | pointwise consistency | `consistent` |
| Map/Map | pointwise consistency | `consistent` |
| Nominal/Nominal fqtn | nominal identity | `consistent` via equality |
| Function/Function | callable shape relation | symmetric consistency plus directional callable plan |

Two details matter:

1. A pair may be semantically consistent but still need conversion at the
   outer boundary. `integer ~ value` does not mean an unboxed integer can be
   copied as a `TValue`.
2. A pair may have the same C spelling and still need different Titan
   treatment. Array and Map both use `Table *`; Option, Function, `value`, and
   raw `TValue` all use a `TValue`-shaped carrier.

## 4. Recursive-call and transitivity audit

### 4.1 What is allowed

Normalize transparent names first:

```text
normalize(alias_chain) = final underlying type
```

Then recursive consistency calls are allowed only on immediate aligned
components:

```text
Array(A) ~ Array(B)     asks A ~ B
Map(Ka,Va) ~ Map(Kb,Vb) asks Ka ~ Kb and Va ~ Vb
Option(A) ~ Option(B)   asks A ~ B
```

Callable adjustment may first align observable source/target streams. Each
ordinary aligned component pair is then compared directly. Reversing the
roles of a parameter pair is not transitive reasoning; it is the ordinary
input direction. Synthesized nil fills, hidden values, tail transfers, and
flexible projections are decisions of the callable-shape helper. They must
not be represented as a non-structural recursive call to `consistent` through
a constructed intermediate type.

### 4.2 What is forbidden

No relation implementation may:

```text
prove A ~ C because A ~ B and B ~ C
compute a closure/cache of prior successful edges
turn A -> B coercion plus B ~ C into A ~ C
turn A ~ B plus B -> C coercion into A ~ C
```

A pair memo used only to terminate recursive type graphs is fine. It must be
keyed by the current pair and may not be used as a graph reachability cache.

### 4.3 Current call graph result

There is no hidden transitive search in current `types.compatible`.

| Location | Recursion | Classification |
|---|---|---|
| `types.lua:1015-1018` | resolve one C typedef side | normalization; okay, move before relation |
| `types.lua:1056-1059` | unwrap legacy scalar typedef | normalization; okay, move before relation |
| `types.lua:1074-1075` | Array elements | structural; okay after leaf cleanup |
| `types.lua:1076-1078` | Map keys/values | structural; okay after leaf cleanup |
| `types.lua:922-1005` | aligned callable components | shape recursion; okay in principle |
| `types.lua:917-920` | compatibility OR coercibility | not transitivity, but invalid coercion lifting |
| `types.lua:976-980` | synthesized optional/raw flexible projection | callable adjustment policy, not core consistency |

The bridge examples in Section 2 are therefore not evidence of an internal
closure algorithm. They show a different problem: a non-transitive relation is
usable repeatedly by a program, and raw retyping does not record evidence for
the intermediate boundary.

Sequential gradual views through `value` are intended:

```text
{integer} -> {value} -> {string}
```

The final string read must guard and may fail. Sequential views through a C
numeric conversion or Option injection are not intended consistency paths and
disappear when those leaves are removed.

### 4.4 Required property tests

Do not assert that consistency is "never transitive"; some individual triples
will happen to compose. Assert its actual laws:

```text
consistent(T,T)
consistent(A,B) == consistent(B,A)
```

and preserve explicit witnesses that prove it is not a transitive relation:

```text
integer ~ value
value ~ string
not (integer ~ string)
```

Repeat the witness under Array and Map.

Also assert:

- normalization does not change a relation result;
- no `coercion`, `dynamic_coercion`, or `written_cast` call occurs from
  `consistent`;
- Array/Map/Option recursion compares only the corresponding normalized
  components;
- callable alignment may be non-structural, but every call it makes to
  `consistent` compares an ordinary aligned pair directly; synthesized
  shape actions do not become non-structural self-calls or consume the result
  of another compatibility/coercion path; and
- `consistent(T, Option(T))` is false.

## 5. Exhaustive Array analysis

### 5.1 Where an alternate view is created

Ordinary finite assignment first calls `trycoerce(source, target)`. There is
no Array-to-Array coercion. `checkmatch` then accepts the pair through
`compatible(target, source)` and no AST conversion is attached.

The same raw Array object can therefore be held under both static element
types.

Projection from `value` to any Array target validates the one shared Array
metatable and canonical backing/proxy cycle. It preserves the existing proxy
and its carried writer; it does not compare the writer with the target view's
element type. An `{integer}` Array carried through `value` can therefore be
viewed as `{value}` without replacement or retagging.

### 5.2 Target proxy and writer representation

The current canonical Array has one shared proxy metatable and one proxy user
value containing the backing. Preserve the shared metatable: it is the
constant-time runtime Array tag used by every boxed read, `value` projection,
generic entry, and nested-backing recovery.

Add a second traced proxy user value for the construction module's
type-directed genuine-Lua writer:

```text
backing Table:
  positive array slots = elements
  integer key 0        = canonical proxy

canonical proxy Udata:
  metatable = shared Array metatable
  uv[0]     = backing Table
  uv[1]     = writer CClosure
```

The compiler emits one writer closure per constructed Array element type per
module and caches it in a private `_mod` slot. Every constructor in that
module/type pair reuses the slot's closure. The closure may capture `_mod`;
placing it in the proxy also keeps it traced for the lifetime of the Array.

There is deliberately no process-wide writer registry or cross-module
interning. Two modules that construct `{integer}` may attach different
closures generated from the same semantic conversion rule. No Titan
operation compares their identities.

This changes the proxy shape (`nuvalue == 1` to `nuvalue == 2`) and therefore
requires the normal clean Titan ABI-0.20 bump and provider/metadata
incompatibility checks. It does not change the exact/native `Table *` Array
representation or the one-to-one backing/proxy identity.

Coordinate that bump with `.agents/plans/interfaces-v1.md`: both changes share
the one ABI-0.20 cutover even if implementation is reviewed as two PRs. The
PR split is not an ABI boundary. The PRs must be stacked or otherwise
coordinated so no ABI-0.20 release, installed provider set, or compatibility
claim is made from the intermediate layout; validation between their heads
uses clean rebuilds, and the final ABI-0.20 tree contains both changes.

### 5.3 Titan writes

An Array write:

1. evaluates the Array and index;
2. converts the right-hand expression to the static element type of the view;
3. boxes that element into a `TValue`; and
4. stores it in the shared backing.

It does not invoke the proxy writer closure. The closure is a Lua-boundary
policy, not an actual-type tag or proof that every slot still contains the
construction element type.

This preserves Titan's transient gradual model:

```titan
local original: {integer} = {17}
local dynamic: {value} = original
dynamic[1] = "wrong"
return original[1] -- strict integer guard raises
```

Gradual bivariance is sound only if every later observation through every
view has an adequate strict guard.

### 5.4 Genuine Lua writes

The single shared proxy `__newindex` remains the only Lua mutation entry. It:

1. validates the shared-metatable proxy and backing cycle;
2. validates/classifies the positive integer index before conversion;
3. obtains the writer closure from `proxy->uv[1]`;
4. handles nil as the representation-independent deletion/hole operation;
5. invokes the writer for a non-nil value;
6. lets the writer apply the canonical dynamic coercion for its construction
   element type; and
7. commits the converted value, capacity/length transition, and GC barrier only after
   conversion succeeds.

The writer uses the same `DynamicCoercionPlan` as written `value as T`, Lua
function formals, module variables, and record fields. Its storage lowering
remains Array-aware: an Array-typed element is normalized to its raw backing in
typed internal storage, while an element of type `value` keeps an Array proxy
boxed.

Because the policy is carried by the object, not the current static view:

- an Array constructed as `{integer}` and widened to `{value}` still converts
  a Lua `2.0` write to an integer and rejects a Lua string; and
- an Array constructed as `{value}` and later projected as `{integer}` still
  accepts a Lua float as `value`; the next Titan integer read rejects that
  float tag.

Making Lua mutation follow the export-site view would require retagging the
canonical proxy or introducing per-view wrappers, both of which would make
behavior alias/order dependent or break canonical Lua identity. This plan
therefore fixes construction-module writer behavior as the intended policy.

After the shared callback loads the carried writer from `proxy->uv[1]`, the
writer need not perform a second identity proof or revalidate invariants
already established by that callback. Mutating/extracting user values through
the debug API is explicitly programmer-responsible and outside the
untrusted-code contract.

### 5.5 Titan reads

Indexing returns `Option(element)`. `codeindexarray` copies the stored slot,
then calls `checkandgetmixed` for the option result. Replace its coercive
present-value path with the strict gradual guard selected for the static
element view.

The current and required guard inventory is:

| Element category | Current behavior | Required gradual read |
|---|---|---|
| integer | accepts integer or integral float | integer tag only |
| float | accepts float or integer | float tag only |
| boolean | Option-present path requires boolean tag | boolean tag only |
| string | requires string tag | string tag only |
| Array | canonical proxy/backing identity | shared proxy-metatable pointer equality; writer untouched; nested elements deferred |
| Map | requires a table | table representation guard; entries deferred |
| nominal record/union | exact metatable | exact nominal metatable |
| Function | copies unchecked | defer signature guard to checked generic call unless exact tag |
| `value` | copies/normalizes Array proxy | dynamic carrier |
| Option base | nil or recursive present helper | nil or recursive strict guard |
| C integer/float/pointer/raw `TValue` | missing from `checkandset` | complete explicit strict/reifiability policy or rejection |
| C owned userdata | exact metatable | exact nominal metatable |
| raw C pointer through `value` | lightuserdata category only | reject under the recommended non-reifiable policy |

The writer closure is never read as part of this guard. The fast outer Array
test remains the same direct comparison used by the current shared-metatable
implementation.

### 5.6 Nested containers

Nested Array backings use a private raw table form in internal slots and a
canonical proxy at Lua/`value` boundaries. `checkandgetmixed` normalizes the
two sanctioned forms.

The tested nested `{{integer}} <-> {{value}}` mutation path raises at the
integer leaf. No unchecked native element load was found.

The shared-metatable design is a performance invariant here. Reading every
inner Array from `{{value}}` recovers the inner canonical proxy and compares
its metatable directly with the one shared Array metatable. It must not look
up a marker through a per-type metatable or inspect `proxy->uv[1]`.

The proof obligation remains recursive:

> every leaf reachable through a nested gradual view must either produce the
> requested native value or raise before producing it.

### 5.7 Function elements

Function elements are boxed. A genuine Lua write reaches the construction
writer and uses the common dynamic-coercion Function policy; it does not turn
the writer closure into evidence that the stored value has an exact callable
signature. Reading one likewise does not validate the complete signature, but
calling it checks the exact function tag:

- exact tag: native fast path;
- branded non-exact Titan closure: strict generic path for arguments/results;
  and
- non-Titan callable/non-callable value: ordinary Lua path, with dynamic
  coercion for results entering Titan or a normal call error.

The tested wrong-result replacement raised cleanly. This remains sound only
if callable component coercions are removed and the generic gradual guard is
separated from Lua's broader coercive boundary behavior.

### 5.8 Operations that do not inspect elements

Array identity, equality, length, proxy conversion, and passing the backing to
an exact Array parameter do not themselves need an element guard. Any later
indexing still does.

None of these operations consults the writer closure. Only construction
stores it and genuine Lua `__newindex` invokes it.

No bulk native read that bypasses `codeindexarray` was found for ordinary
Titan Arrays.

### 5.9 Open construction and forwarding

Open Array/Map/function elements are the current exception: checker acceptance
is not preserved as a plan, and coder paths synthesize unsupported casts. All
open consumers must use the same checker-produced element adjustment.

Every generated Array construction path, including open positional
construction and standalone `main`'s `{string}` arguments, must attach the
correct writer closure. The standalone driver may generate/use its own fixed
string writer; it does not justify a global writer registry.

### 5.10 Array conclusion

For ordinary Titan value-domain leaves, mutable gradual views appear capable
of the requested "valid value or checked error" behavior. The statement is
conditional on:

- removing conversion leaves from consistency;
- using strict gradual guards instead of direct-coercion helpers;
- keeping the shared proxy metatable as the direct Array tag;
- attaching a module-local, per-constructed-type coercive Lua writer to every
  proxy and invoking it only on genuine Lua writes;
- completing the C/TValue guard matrix; and
- choosing an honest raw-pointer policy.

Until those are done and covered, "Array bivariance is sound" is not an
established repository invariant.

## 6. Other recursive and compound cases

### 6.1 Maps

Map values use the same `checkandgetmixed` path as Array elements, including
the same C-element compiler abort.

The Array Lua-write repair does not apply to Maps. An Array is represented to
Lua by a canonical proxy, so every ordinary Lua write reaches the shared
`__newindex` and its carried writer closure. A Map is the ordinary Lua table
itself; there is no proxy, write interception, or provenance bit that
distinguishes a Lua-origin float from the same float stored through a Titan
`{value}` view.

**Decision:** every typed Titan Map value read uses the strict target tag/shape
guard, regardless of write origin. A float stored by raw Lua into a Map later
read as `integer` raises rather than being converted, even though the same
float may succeed under `value as integer` or at an intercepted genuine-Lua
sink. The implementation must not add origin tracking, guess provenance, or
select the canonical dynamic-coercion matrix on a Map read. Any future
coercive Lua Map-write design would require a representation/boundary change;
it cannot be simulated by loosening reads.

Map keys are more subtle:

- indexing/writing converts the *query expression* under the current static
  key view and boxes it;
- the table does not re-read all stored keys on lookup;
- changing the key view can change which entries are reachable or collide;
  and
- any future key-yielding iterator must guard yielded keys just like values.

Pointwise gradual consistency of key types is defensible for a dynamic Map,
but conversion leaves are not. In particular, C numeric/pointer conversions
must not change the hashing/equality domain merely because they were lifted
through Map.

Add Map tests for:

- value keys in both view directions;
- integer/float distinction;
- raw Lua mutation followed by strict integer, float, boolean, nominal,
  Interface, Function, and C-valued reads;
- the same wrong dynamic value through both Titan and Lua writes, proving read
  behavior is origin-independent;
- Array/Map/function identity keys;
- nested Map values;
- key iteration if/when Titan adds a typed built-in iterator; and
- rejection of every C-conversion bridge.

### 6.2 Functions

Current callable assignment has two separable parts:

1. shape adjustment (fixed prefixes, ignored surplus, nil filling, input
   tails, hidden results, flexible projections); and
2. component acceptance.

The shape algorithm is not itself the problem. The component predicate is.

The replacement callable classifier must:

- take `(source_actual, target_expected)` explicitly;
- align arguments/results according to Titan's call adjustment;
- compare each aligned component through gradual-use logic with ordinary
  coercions disabled;
- recurse into nested callable adjustment where the aligned component itself
  is a Function;
- record nil-fill, ignored slots, tail transfer, and flexible projection as
  explicit shape actions;
- reject shared `T`/`T?`, integer/float, truthiness, C conversion, and
  interface-wrapper mismatches; and
- retain exact function tags as the only native fast path.

Runtime enforcement follows the three-entry rule from §2.7: a non-exact
branded Titan closure uses its strict trailing stack entry for the actual
callee signature, while a genuine Lua call alone uses the coercive entry.
The generic caller strictly checks a branded Titan closure's result projection.
Results from a non-Titan Lua callable instead cross the same dynamic boundary
as any other Lua-produced value and consume `DynamicCoercionPlan` for the
expected result type.

The current raw-flex fallback deserves a named action:

- an actual flexible `T` tail projected to expected fixed `T?` is an optional
  projection;
- projection to fixed `T` may remain a partial callable adjustment that raises
  if the result is absent, if the maintainer wants to preserve current direct
  call adjustment;
- neither case licenses `T -> T?` for an ordinary fixed result pair.

### 6.3 Options

Options do not currently recurse in `compatible`. The repaired symmetric
consistency relation should compare `Option(A)` and `Option(B)` pointwise when
`A ~ B`.

These remain coercions, not consistency:

```text
T -> Option(T)
Nil -> Option(T)
Option(T) -> T
Option(A) -> Option(B) when A requires a coercion to B
```

`coercion` may contain explicitly enumerated composite Option plans. That is
not permission for arbitrary structural recursion:

```text
option_map(base_plan)
option_force_then(base_plan)
base_plan_then_option_wrap
whole_slot_to_TValue
```

Each plan records nil behavior and lowering order.

### 6.4 Transparent aliases and typedefs

Titan source aliases already resolve to the RHS type object. Legacy
`Type.Typedef` and C `Type.CTypedef` wrappers should be collapsed by one
cycle-safe normalization helper before any relation dispatch.

Do not represent transparency as relation edges in tables or caches. Tests
should compare the normalized result directly and prove chains of aliases do
not affect consistency/coercion classification.

### 6.5 Nominal records, unions, and future interfaces

Records/unions are consistent only with the same nominal type. Future
interfaces are likewise consistent only with the same nominal interface.

Structural satisfaction is a private predicate used to construct one direct
outer coercion plan:

```text
coercion(source_nominal, target_nominal, cast_site_policy)
  -> interface_wrapper(method_adjustments)
```

Expression types on both sides are `Type.Nominal`. The cast-site policy
callback resolves their owner descriptors, requires a record/union source and
an Interface target, applies method visibility, and returns the adjustment
payload. The central relation must not dispatch on descriptor tags that never
appear as ordinary scalar expression types.

It does not make the two outer types consistent and does not make
`{Record}` consistent with `{Interface}`.

Interface method matching consumes the repaired callable-adjustment
classifier; it must not use scalar coercions recursively. A concrete
`clone(): Record` therefore does not satisfy a required `clone(): Interface`;
the concrete method must itself declare `clone(): Interface`, with its body
performing the direct scalar conversion.

### 6.6 C types

Within consistency:

- normalize transparent C typedefs;
- otherwise require exact C declaration/value identity; and
- do not include numeric, address, pointer, string, ownership, null, or
  `TValue` crossing rules.

Those operations remain available as direct coercion/written-cast plans.

`value` and C types need the reifiability decision in Section 8. Merely having
a `TValue` representation is not proof that the precise C type can be checked
later.

## 7. Replacement model: no subtyping required

The first audit proposed `is_a` and consistent subtyping. Remove them from the
plan. They add vocabulary without solving a Titan operation.

The minimal semantic/operational split is:

```lua
types.normalize(typ)

types.consistent(left, right)
    --> boolean

types.coercion(source, target)
    --> false | CoercionPlan

types.callable_adjustment(source_actual, target_expected, policy)
    --> false | CallablePlan

types.assignment_adjustment(source, target, policy)
    --> false | AdjustmentPlan

types.dynamic_coercion(target)
    --> false | DynamicCoercionPlan

types.written_cast(source, target)
    --> false | WrittenCastPlan

types.comparable(left, right)
    --> boolean | ComparisonPlan
```

Make a clean API break: remove `types.coerceable`,
`types.explicitly_coerceable`, and `types.compatible` after their callers
migrate. Do not preserve any of those names as boolean wrappers or reuse them
for a different directional relation.

### 7.1 `consistent(left, right)`

Required laws:

- reflexive;
- symmetric;
- non-transitive, with explicit witnesses;
- no call to `coercion`, `dynamic_coercion`, `written_cast`, or assignment
  adjustment.

Constructor rules after normalization:

```text
equal types                           consistent
value and a soundly gradual type      consistent
Array(A), Array(B)                    iff A ~ B
Map(Ka,Va), Map(Kb,Vb)                iff Ka ~ Kb and Va ~ Vb
Option(A), Option(B)                  iff A ~ B
same nominal                          consistent
different nominals                    inconsistent
concrete C types                      exact only
```

For Functions, use a symmetric consistency helper:

```text
function_consistent(F,G) =
  shape_consistent(F,G) or shape_consistent(G,F)
```

`shape_consistent(source_actual, target_expected)` may align Titan's callable
streams non-structurally. That non-structural traversal is not itself a
problem: every recursive `consistent` query is on an ordinary aligned
component pair directly. Nil fills, hidden values, and flexible projections
are internal shape rules rather than `consistent` calls on synthesized
intermediate types. The helper never calls `consistent` on an intermediate
relation result, consults coercion, or searches for a path through another
type.

The symmetric relation is useful for structural descent and equality
comparability. Actual assignment still consumes the directional
`callable_adjustment(source, target)`.

### 7.2 `coercion(source, target)`

Return a complete plan for:

- Titan numeric conversions;
- explicitly enumerated Option introduction/force/base composition;
- C/Titan numeric conversion;
- C address, pointer, array-decay, owner, qualifier, and string conversions;
- raw `TValue` whole-slot operations;
- any retained direct raw-pointer dynamic operation under the selected FFI
  policy; and
- concrete record/union nominal to Interface nominal wrapper construction,
  authorized only by a cast-site callback that resolves and validates both
  descriptors.

Do not recurse generically through:

- Array;
- Map;
- Function;
- record/union/interface fields or methods.

Do not infer a plan by composing two arbitrary known coercions. The only
composite plans are named language rules, chiefly Option and address/lifetime
operations.

### 7.3 `callable_adjustment(source_actual, target_expected)`

Retain the current shape matrix, with corrected component policy.

Inputs:

- shared fixed position: target callers supply the expected parameter; adapt
  it gradually to the actual parameter with ordinary coercions disabled;
- actual fixed suffix: record nil fill and, when present, expected-tail
  transfer as explicit shape obligations;
- actual input tail: record transfer of expected fixed suffix/tail;
- shorter non-variadic actual: record ignored expected suffix/tail;
- untyped C varargs: exact only.

Results:

- shared fixed position: gradually guard actual result as expected result;
- actual fixed surplus under finite target: hidden;
- actual flexible projection: record optional/partial projection explicitly;
- target flexible tail: guard each observed actual fixed/tail result;
- fixed actual under target flexible tail: may end.

For every ordinary aligned component:

```text
integer vs float          reject
T vs Option(T)            reject
C-convertible pair        reject
record vs Interface       reject
value hole                gradual guard/inject/project plan
nested Function pair      recurse into callable adjustment
consistent container pair gradual view plan
```

Nil fill and flexible absence are shape-specific actions, not evidence that
the corresponding ordinary component coercion lifts through Function.

### 7.4 `assignment_adjustment(source, target, policy)`

Return exactly one of:

```text
identity
direct_coercion(CoercionPlan)
gradual_view(GuardPlan)
callable(CallablePlan)
rejected
```

Recommended classification order:

1. normalize;
2. exact identity;
3. `value` injection/projection or same-outer structural gradual view;
4. direct outer coercion authorized in this syntactic context;
5. directional callable adjustment;
6. rejection.

This preserves direct language coercions without lifting them:

```text
integer -> float              direct coercion
integer -> integer?           direct coercion
{integer} -> {float}          rejected
{integer} -> {integer?}       normalized/rejected by element policy
() -> integer
  -> () -> integer?           rejected
R -> I                        direct Interface coercion
{R} -> {I}                    rejected
```

For `value` pairs, the returned plan records whether the outer operation is an
injection/projection or a same-outer structural view. It never relies on a
boolean relation to guess storage.

An Option structural view consumes its recursive strict guard at the sink:
nil passes, while the present payload is the immediate component observation.
Unlike Array/Map/callable carriers, an Option has no mutable backing on which
to preserve source-view provenance for a later read or call.

An Array `gradual_view` preserves the existing backing, canonical proxy, and
writer closure. Projection from `value` validates only the shared Array
metatable/canonical cycle. No view change synthesizes a target-type writer,
compares writer identity, or creates another proxy.

### 7.5 Strict observation guards are not dynamic coercions

Introduce a separate guard classifier/lowering for observations through a
gradual view:

```lua
types.gradual_guard(target)
    --> false | GuardPlan
```

It is also the guard used by every typed Titan Array/Map read. It depends on
the requested target type, never on a claimed Titan/Lua storage origin.

It must not automatically inherit:

- integral-float-to-integer conversion;
- integer-to-float conversion;
- truthiness;
- pointer conversion; or
- Option introduction/force.

Define one canonical target-directed dynamic operation:

```lua
types.dynamic_coercion(target)
    --> false | DynamicCoercionPlan
```

`value as T` applies this plan and raises normally if it cannot produce `T`;
`value is T` evaluates the same plan's acceptance predicate without raising or
returning the converted result. A genuine Lua-to-Titan boundary applies the
same plan implicitly: from Titan's point of view, crossing that boundary
requests the explicit dynamic conversion. `types.written_cast(value, T)`
therefore embeds/delegates to `dynamic_coercion(T)` rather than selecting a
strict guard, and the Lua-entry/field/Array lowerings consume that exact same
plan rather than maintaining a second matrix.

The initial matrix preserves the documented broad dynamic behavior:

- `integer` accepts an integer or an exactly integral, in-range float and
  produces an integer;
- `float` accepts either numeric representation and produces a float;
- `boolean` uses Lua truthiness, so `value is boolean` is correspondingly
  total;
- `string` and nominal values use their existing exact runtime category or
  metatable checks, while `value`/raw-`TValue` targets copy the complete slot;
- Array and Map targets validate only their outer runtime kind and retain the
  same object as a typed view; their later Titan element/value reads remain
  strict and perform no deep conversion;
- Function targets preserve the existing unchecked boxed value and defer
  callability/signature verification to invocation;
- Option targets handle nil first and otherwise apply the target element's
  dynamic plan; and
- C scalar/pointer targets follow the explicit policy selected in Section 8.

Generate the native-result form currently associated with `checkandget` and
the boxed-store form currently associated with `checkandset` from this one
semantic plan. A Lua call argument, a Lua record/module field write, and a
non-nil Lua Array write to the same target type must accept, reject, and
convert identically. Representation alone must not change the result.

Recursive Option use is intentional. For example, `value as boolean?`
preserves nil and truthiness-converts every present value; `value is boolean?`
is therefore total. Existing exact-tag behavior for that written cast is
documentation/implementation drift to remove, not an exception to the shared
matrix.

For a future Interface target `I`, `DynamicCoercionPlan(I)` accepts only an
existing wrapper with the exact nominal `I` metatable. It must not discover
that a bare record/union implements `I` or synthesize the checker-planned
`R/U -> I` wrapper coercion. The same rule applies to written `value as/is I`,
Lua function arguments, record/module fields, Array writers, and the present
arm of `I?`; only nil gets the ordinary optional case. Concrete-to-Interface
conversion remains a direct Titan coercion with statically known concrete
owner and method mapping. Raw Lua Map writes remain unintercepted: a bare
implementer stored into a `Map<K,I>` is not wrapped, and the later strict
Interface read rejects it.

The Array writer closure from Section 5 consumes the same
`DynamicCoercionPlan` for its construction element type, with one
Array-specific outer rule: nil deletes a slot before element conversion. Thus
a Lua integral float may still be converted for an integer Array even though
an integral float already stored through a Titan `{value}` view fails the
strict integer gradual guard on read.

A generic Titan function-value call makes the same distinction. Exact-tag
Titan closures use their native entry. A branded non-exact Titan closure uses
the strict stack entry stored in its final upvalue; a genuine Lua call still
enters `CClosure.f` and consumes `DynamicCoercionPlan` for every argument.
Non-Titan callables retain Lua's ordinary call path, and their results consume
`DynamicCoercionPlan` as they enter the expected Titan result slots. Do not
route the branded strict function entry through `DynamicCoercionPlan` or the
Array writer through the strict guard.

### 7.6 Comparison is separate

Equality has no source/target direction. Route `==`/`~=` through a symmetric
`comparable` policy.

It may intentionally allow:

- exact/gradually consistent pairs;
- mixed Titan integer/float comparison;
- option lifting already performed by the checker; and
- function pairs accepted by symmetric callable consistency.

Ordering keeps its current numeric/string policy.

Written `as`/`is` likewise consumes only `written_cast`, never consistency OR
coercion booleans assembled ad hoc. Its `value -> T` branch is exactly the
canonical `dynamic_coercion(T)` plan above; other written source/target pairs
retain their separately enumerated cast plans.

### 7.7 Stored plans are the coder's authority

The checker must attach the complete operational plan at every observation,
conversion, call boundary, and comparison. The coder validates and lowers
that plan; source/target tags may select a representation-specific emitter
only after the plan kind, operation, and target have been checked.

In particular:

- every typed Array/Map bracket node carries its recursive `GuardPlan`,
  including the outer Option produced by ordinary indexing;
- strict function formals, variadic elements, fixed results, and open results
  carry their own `GuardPlan`s, while genuine-Lua counterparts carry
  `DynamicCoercionPlan`s;
- a written gradual or callable cast consumes the stored view/adjustment plan;
  Array/Map/callable casts preserve representation, while an Option view
  observes its immediate present payload eagerly;
- the non-raising `is` lowering consumes the same `WrittenCastPlan` as `as`,
  including partial scalar and recursive Option coercions;
- equality consumes and validates one symmetric `ComparisonPlan`, including
  any explicit one-sided injection into `value`;
- each deferred constructor/open-run sink classifies its final element edge
  exactly once, after inference/context selection, and stores that one plan
  on both the sink and producer annotation; and
- malformed recursive structural `Type` tables cannot use a pending pair as
  evidence for non-identity consistency. Titan aliases cannot construct such
  graphs, and recursive records, unions, and Interfaces stop at nominal
  leaves, so this is not a fixed-point rule in the language relation.
  Completed-pair memoization may reuse results for shared acyclic alias DAGs,
  but it never turns a pending pair into evidence.

Add negative unit tests for missing, rejected, unknown, mismatched, and
recursively mismatched `GuardPlan`, `DynamicCoercionPlan`, `CoercionPlan`, and
`ComparisonPlan` values. These assertions are compiler-integrity checks; they
must not rerun `consistent`, `coercion`, or `written_cast` during lowering.

## 8. Reifiability and the FFI boundary

Add a predicate distinct from `has_tvalue_representation`:

```lua
types.has_sound_gradual_guard(typ)
```

`has_tvalue_representation` answers "can bits be boxed in a `TValue`?"
`has_sound_gradual_guard` answers "can a later observation establish this
specific target type or raise before using it?"

Initial classification:

| Type | Boxable | Sound gradual guard today |
|---|---:|---:|
| Titan integer/float/boolean/string | yes | yes, after strict-guard split |
| Array | yes | yes, shared-metatable outer guard plus recursive strict observations; Lua writer is not consulted |
| Map | yes | yes, outer guard plus recursive observations |
| nominal | yes | yes, exact metatable |
| Function | yes | delayed until call; requires strict generic guard |
| Option(T) | yes when T boxable | only when T has a sound guard |
| C owned userdata | yes | yes, exact metatable |
| C integer/float | yes | guardable with the implemented target-profile tag/range policy below |
| raw C pointer | yes | no precise pointee guard with lightuserdata |
| raw C `TValue` | itself dynamic | safe only as whole-slot dynamic carrier |
| C aggregate/function value | no scalar box | no |

### 8.1 C scalar representability policy

Every C numeric conversion that can lose range or invoke invalid C behavior
must use one target-profile-driven checked conversion primitive. This includes
strict and dynamic boxed reads, predicates, direct coercions, written C
numeric casts, C/Titan carrier crossings, Array/Map/Option slots, function
arguments/results, and integer-to-floating usual-arithmetic conversions whose
selected C target range is not provably sufficient. A generic raw C cast is
reserved for pointer-like operations, the C-semantics exceptions below, and
profile-proven total numeric conversions.

The policy is:

- strict `CInteger` requires an integer Lua tag and exact representability in
  the target signed/unsigned width; `_Bool` admits only `0` and `1`;
- dynamic `CInteger` also accepts an exactly integral Lua float that first
  fits `lua_Integer`, then applies the same target-range check;
- strict `CFloat` requires a float Lua tag; dynamic `CFloat` accepts either
  numeric tag. Both apply the target float-range rule;
- same-rank or widening floating conversion is total and preserves finite
  values, infinities, and NaNs;
- narrowing floating conversion rejects non-finite and out-of-range values
  before the C cast. Finite in-range rounding and underflow are allowed; exact
  round-trip equality is not required;
- floating-to-integer conversion rejects non-finite values and values whose
  truncation-toward-zero result is outside the exact target interval, then
  performs the cast;
- implicit/static carrier, strict, dynamic, and gradual integer crossings
  reject non-representable values rather than wrapping or relying on
  implementation-defined signed narrowing;
- explicitly written C integer-to-integer casts and checker-selected integer
  promotions/usual-arithmetic integer conversions retain ordinary C
  conversion semantics; this exception does not include a potentially
  out-of-range integer-to-floating operator conversion; and
- C-to-Titan carrier conversion checks against `LUA_MININTEGER`,
  `LUA_MAXINTEGER`, and the Lua floating range before narrowing.

The compiler obtains integer bounds/ranks and float rank, mantissa, radix, and
maximum exponent from the authoritative target profile produced by the active
C toolchain. It does not infer them from `uname`, the compiler host, or C type
spelling alone. The acceptance predicate used by `is` is generated from the
same conversion description as the committing `as`/boundary operation, so
they cannot drift.

Recommended initial-release policy:

- make `value -> raw C pointer` written/unsafe rather than implicit;
- reject Array/Map/Option/Function gradual paths whose eventual leaf is a raw
  C pointer;
- retain direct statically typed C pointer conversions through `coercion`;
- retain C owned userdata gradual crossing; and
- revisit tagged raw-pointer boxes only if ergonomic demand justifies them.

If the maintainer instead deliberately scopes all raw C pointers outside the
soundness promise, both manuals must say that this applies to implicit
`value`/container paths too, not only explicit casts.

## 9. Checker-to-coder plans

The checker must elaborate every accepted edge once.

### 9.1 Fixed expressions

Replace:

```text
trycoerce(...)
checkmatch(...)
```

with one `assignment_adjustment` result consumed by a single AST annotation
or explicit node.

The temporary migration may keep `trycoerce`, but no accepted nonidentity edge
may be represented only by changing `_type`.

### 9.2 Open expressions

Every open result/variadic/constructor edge records:

```text
identity
gradual_view(guard)
direct_element_coercion(plan)
rejected
```

All three coder sites consume that exact annotation. They may assert it; they
must not rerun relations or synthesize a naked semantic `Ast.ExpCast`.

### 9.3 Callables

A function-typed assignment carries a complete `CallablePlan` or changes the
function value's static view with a durable annotation available at its calls.

At minimum, code generation must know:

- exact tag fast path eligibility;
- fixed argument/result projection;
- ignored slots;
- nil-filled slots;
- input/output tail transfer;
- gradual guards at every observed component; and
- flexible absence handling.

Do not reconstruct this from two type objects in the coder.

### 9.4 Array construction and Lua writers

During checker elaboration, record each Array constructor's final
context-adjusted Array/element type. During code generation, collect those
normalized element types for every constructor emitted by the module.
Allocate one private module user-value slot and one generated writer CClosure
for each distinct constructed type. The writer lowering:

- captures the constructing module's `_mod` when conversions need its nominal
  or C caches;
- implements the target type's `DynamicCoercionPlan`;
- produces the correct internal/boxed Array slot representation;
- performs no store until conversion succeeds; and
- has stable type-based diagnostics rather than an arbitrary constructor
  source location.

Every construction site obtains the cached closure and passes it to the
runtime along with capacity. `titan_array_new` creates a two-user-value proxy,
stores the backing in C `uv[0]`, stores the closure in C `uv[1]`, and preserves
the backing key-0 reverse link and all required barriers.

The shared runtime `__newindex` dispatches the receiver-carried closure. It
does not select a writer from the current static view, a global registry, or a
type-identity comparison. Ordinary Array validation and all Titan reads
continue to compare only the proxy's shared metatable and never load the
writer slot.

Generated standalone-main construction must provide the corresponding fixed
`{string}` writer without introducing a global writer registry.

### 9.5 Function entry selection

For every Titan function value that can be constructed—top-level function,
local function, static, lambda, ordinary bound method, and future bound
Interface method—the coder emits:

- the existing typed native entry;
- a coercive genuine-Lua stack entry;
- a strict Titan-generic stack entry; and
- one canonical closure whose `f` is the coercive entry and whose header
  retains module, type tag, and native pointer in slots 0 through 2 plus the
  opaque Titan-function brand in slot 3, whose existing captures/receiver
  begin at slot 4, and whose final slot is the strict-entry LCF.

The checker records the callable adjustment and strict argument/result guard
plans. The coder must not infer them by calling a semantic relation.

The strict stack entry uses the runtime function's own declared parameter and
result types. Its hidden argument is the original canonical closure, not a
replacement identity. It passes that closure as `_fn` to the native entry,
which keeps lambda captures and bound receivers available at their existing
indices.

Top-level/static/local closures and lambdas are built by the module that emits
their strict entry, so the trailer is installed directly. A bound method may be
constructed in another module; export/recover its strict bound entry in
parallel with the existing bound native and Lua trampolines, including symbol
collision checks, DSO lookup, static linking, direct-module accounting, and
standalone protocol probes.

Use the same ABI-owned random 64-bit lightuserdata sentinel in fixed upvalue 3
of every Titan function closure. Generic dispatch first proves that the C
closure has at least five upvalues and then compares that slot's raw pointer
bits. It does not query the registry or inspect any other `ttis*` shape. The
sentinel is never dereferenced and is not a compatibility token; exact
function-type identity remains the separate canonical tag in upvalue 1.

Lua's `MAXUPVAL` remains a hard representation limit. The checker must account
for the four fixed header upvalues plus the strict trailer before code
generation, diagnose a lambda whose captures would exceed the remaining
budget, and add boundary tests for the largest accepted and first rejected
capture counts.

### 9.6 Completeness assertions

For every plan kind:

- one checker construction site;
- one coder lowering;
- one relation-level test;
- one checker AST test; and
- one end-to-end test.

The compiler should fail a developer assertion naming an unknown plan kind,
but no checked source program may reach it.

## 10. Caller migration

Line numbers are from this audit's checkout.

| Current caller | New operation |
|---|---|
| `checker.lua:258-274` `checkmatch` | `assignment_adjustment(found, expected, context)` |
| `checker.lua:1588-1625` `trycoerce` | consume only `coercion(source,target)` plan |
| `checker.lua:1663-1666` nil adjustment | dedicated missing-value/call-shape plan |
| `checker.lua:2009-2038` open list | stored open-element adjustment |
| `checker.lua:2192-2219` positional constructor | reuse stored open-element adjustment |
| `checker.lua:3720-3740` C call lifetime | plan metadata from C coercion |
| `checker.lua:4208-4251` `as`/`is` | `written_cast` plan; source `value` embeds `dynamic_coercion(target)` |
| `checker.lua:4660-4682` equality | `comparable(left,right)` |
| `coder.lua:471-745` `checkandget` family | split native-result lowerings by explicit annotation: strict observation guard versus canonical dynamic coercion |
| `coder.lua:747-894` `checkandset` family | generate the boxed-store form of the same `DynamicCoercionPlan` used by Lua arguments and written value casts |
| `coder.lua:4058-4061` nil adjustment | consume checker annotation |
| `coder.lua:4243-4279` vararg forwarding | consume open/callable plan |
| `coder.lua:4459-4489` result-run element | consume open plan |
| `coder.lua:7249-7265` positional fill | consume open plan |
| `coder.lua:380-385`, `942-1175` Array/Map boxing/mixed guards | retain one shared Array metatable pointer test; every typed Array/Map read uses strict target guards without provenance or writer lookup |
| `coder.lua:8702-8729` bracket/written casts | choose strict projection versus `DynamicCoercionPlan` from the checker annotation, never from `Ast.ExpCast` shape alone |
| `coder.lua:7208-7214` Array construction | pass the module-cached writer closure for the constructed element type |
| module private-slot/init emission | generate/cache one writer closure per constructed Array type; no registry publication |
| `titan-runtime/titan.c:58-108`, `295-350` proxy/backing helpers and construction | change proxy shape to two user values; preserve shared-metatable validation and canonical cycle |
| `titan-runtime/titan.c:236-250` Array `__newindex` | nil deletion or dispatch the receiver-carried coercive writer before mutation |
| `titan-runtime/titan.h:338-361` Array ABI | accept/install the writer and document the two-user-value proxy |
| `driver.lua:2294-2303` standalone argv Array | attach the fixed `{string}` writer |
| `types.lua:917-1005` callable helper | `callable_adjustment`, consistency-only components |
| `coder.lua:4650-5081` `codevaluecall` | exact static tag uses native entry; non-exact closure with the fixed ABI brand pushes strict LCF + hidden original closure and strictly guards results; non-Titan callable keeps ordinary Lua path and dynamically coerces Lua-produced results |
| `coder.lua:9066-9340` `genluaentry` | refactor one stack-entry shell into coercive genuine-Lua and strict Titan-generic policies |
| `coder.lua:9718-10048`, `10856-10942` function-value construction | insert the fixed brand at upvalue 3, shift captures/bound receivers to begin at 4, append the strict-entry LCF, and enforce `MAXUPVAL` |
| `titan-runtime/titan.h` function closure brand | define one opaque random 64-bit pointer sentinel; compare it only as raw bits and never dereference it |
| `titan-runtime/titan_uv.c`, `titan-runtime/titan_coro.c` native callback dispatch | audit the branded header/trailer while retaining native pointer in upvalue 2 |
| Interface method matching | `callable_adjustment(concrete, required)` |
| Interface bound-method generation | retain the Interface wrapper at upvalue 4 and append the same strict generic trailer |

After migration:

```sh
rg 'types\\.compatible|types\\.coerceable|types\\.explicitly_coerceable' \
  titan-compiler
```

must show only deliberate temporary wrappers or no hits.

## 11. Test plan

### 11.1 Relation truth tables

Expand `spec/types_spec.lua` with table-driven cases for:

- normalized equality;
- symmetric consistency;
- direct coercion kind;
- dynamic-coercion kind;
- written-cast kind;
- callable direction;
- assignment adjustment kind;
- equality comparability; and
- sound gradual guardability.

Required rows:

| Source | Target | Consistent | Direct coercion | Assignment |
|---|---|---:|---:|---|
| integer | integer | yes | no | identity |
| integer | float | no | yes | numeric coercion |
| integer | value | yes | no | boxed gradual injection |
| value | integer | yes | no | strict gradual projection |
| integer | integer? | no | yes | option introduction |
| integer? | integer | no | yes | checked force |
| `{integer}` | `{value}` | yes | no | gradual view |
| `{value}` | `{integer}` | yes | no | gradual view |
| `{integer}` | `{float}` | no | no | reject |
| `{float}` | `{C-double}` | no | no whole-container plan | reject |
| `() -> integer` | `() -> integer?` | no at fixed result pair | no | reject |
| `() -> integer` | `() -> float` | no | no callable coercion | reject |
| compatible-arity function `F` with a `value` component | compatible-arity function `G` | yes when aligned components are consistent | no scalar lift | directional callable plan |
| record R | interface I | no | wrapper plan | coercion |
| `{R}` | `{I}` | no | no | reject |
| raw C pointer | value | no | direct boxing plan to untyped lightuserdata | automatic coercion; recovery remains written/unsafe |

Add target-directed `DynamicCoercionPlan` rows independently of this implicit
assignment table: integer/integral-float, float/both numeric tags,
boolean/truthiness, string, `value`, nominal, Array, Map, Function,
Option-present/nil, C categories, and Interface exact-wrapper-only. For each
row, the written `value as/is T` and genuine-Lua boundary classifications must
be identical.

### 11.2 Laws

Test:

- consistency reflexivity;
- consistency symmetry;
- the explicit non-transitive `integer/value/string` witness;
- the same witness under Array and Map;
- normalization invariance for long alias/C-typedef chains;
- no `T ~ T?`;
- no Function component coercion lifting;
- no Array/Map conversion lifting;
- no arbitrary coercion composition;
- comparability symmetry; and
- serialization/rehydration stability.

Instrument or dependency-inject the relation module in one test so calling
`coercion`, `dynamic_coercion`, or `written_cast` from `consistent` fails
immediately.

### 11.3 Confirmed regression programs

Add the programs from Sections:

- 2.3 C-double Array bridge — must be rejected after repair;
- 2.4 fixed function component coercions — must be rejected;
- 2.5 Option function chain and Array-of-functions chain — must be rejected at
  the first invalid callable assignment;
- 2.6 ordinary wrong value mutation — must still compile and raise cleanly;
- 2.7 dynamic-coercion-vs-strict-guard examples — an implicit Titan
  `value -> T` projection and a gradual Array/Map read reject the wrong
  numeric/boolean tag, while written `value as T` and every genuine-Lua sink
  apply the same selected dynamic conversion;
- 2.8 both open-run compiler aborts — must compile/run;
- 2.9 C integer Array and Map reads — must compile/run; and
- equality/explicit-only regressions from the first audit.

### 11.4 Array/Map guard matrix

For every `has_tvalue_representation` category, test:

- exact store/read;
- wrong dynamic store then typed read;
- both gradual view directions;
- nested Array;
- Map value;
- Option-present and nil;
- Lua-origin value;
- open constructor/result;
- function call if callable; and
- GC survival across the guard.

The matrix must include C integer, C float, raw `TValue`, C owned, and the
selected raw-pointer rejection/policy.

Array rows must additionally distinguish the source channel rather than
testing only the final stored `TValue`:

- exact Titan construction/write followed by strict read;
- wrong value stored through a Titan gradual view followed by strict read;
- genuine Lua `__newindex` with an automatically convertible value, followed
  by a strict read that sees the converted target tag;
- genuine Lua `__newindex` with a rejected value, proving no slot/length
  mutation occurred;
- Lua nil deletion, independent of element conversion policy;
- `table.*` mutation through the proxy, proving it reaches the same writer;
- an Array constructed as `{integer}` and widened to `{value}`, proving Lua
  still uses its integer writer;
- an Array constructed as `{value}` and projected to `{integer}`, proving Lua
  still uses its value writer and the later Titan integer read remains strict;
- `value` holding `{integer}` projected to `{value}` without replacing or
  comparing the writer closure;
- nested `{{value}}` reads whose inner Arrays were constructed under another
  element view;
- the standalone `{string}` argument Array; and
- the same constructed Array type from two modules, proving distinct
  module-local writer closures have identical semantics and require no global
  identity.

Exercise Array writers for integer, float, boolean/truthiness, string,
nominal, Map, nested Array, Function, `value`, C scalar, and the selected
raw-pointer policy. For every applicable target, assert parity with genuine
Lua function-formal and record/module-write acceptance from the same
`DynamicCoercionPlan`.

Representation/runtime tests must prove:

- the proxy has exactly two user values, backing then writer;
- backing key 0 and proxy user value 1 retain the one-to-one canonical cycle;
- the writer closure and captured `_mod` survive full and generational GC;
- writer allocation/invocation and conversion-triggered stack relocation do
  not stale the receiver, backing, index, or incoming value;
- an invalid index is rejected before invoking the writer, and nil beyond the
  current capacity remains an allocation-free no-op;
- ordinary boxed/nested Array validation performs direct shared-metatable
  pointer equality and does not inspect the writer slot;
- only shared `__newindex` loads/invokes the writer;
- failed conversion cannot partially grow, change length, or store; and
- old/new proxy layouts are rejected across the required ABI bump.

Generated-code/provider cases must cover:

- fixed, empty, nested, open/flexible, and variadic positional construction;
- contextual construction where source expressions are adjusted to a
  different final element type, proving the final constructed type selects
  the writer;
- an imported nominal element whose writer uses the constructing module's
  captured `_mod`;
- `table.insert`, destination `table.move`, and `table.remove` through the
  shared proxy callbacks;
- DSO and static-provider passage without changing proxy/writer identity; and
- a Lua write after the constructing function/module initializer has returned
  and after GC.

Do not add defensive tests requiring correctness after `debug.setuservalue`
breaks the proxy. The documented debug contract makes preservation of Titan
invariants the programmer's responsibility.

Keep Map rows separate. They must not claim Lua-write coercion or provenance
merely because the Array proxy now provides it. A raw Lua write of an
integral float to an integer-valued Map, or a truthy nonboolean to a
boolean-valued Map, must raise on the later Titan read just like the same
`TValue` written through a Titan `value` view. Include nominal, Interface,
Function, Array/Map, Option-present, C-value, and wrong-tag rows; no expected
result may depend on write provenance.

### 11.5 Dynamic-coercion parity

For every supported target category, run one table of dynamic inputs through:

- written `value as T`;
- the non-raising `value is T` predicate;
- genuine Lua calls into every generated Titan-entry role, including ordinary
  exported functions, record/union methods and bound methods, and Interface
  direct/bound method entries;
- Lua writes to Titan module and record fields;
- a non-nil Lua Array `__newindex` writer; and
- a result returned by a non-Titan Lua callable into an expected Titan result
  slot.

All conversion-bearing contexts must agree on acceptance and the produced
Titan value; `is` agrees on acceptance without returning the conversion. The
only Array-specific outer exception is nil deletion before element conversion.
Record/module `checkandset`, function-entry `checkandget`, Array writer
lowering, non-Titan result lowering, and written-cast lowering must be generated
from the same `DynamicCoercionPlan`, not hand-maintained switch copies.

Use paired three-way witnesses to keep that shared plan out of consistency:

- `local v: value = 3.0; local i: integer = v` raises a strict tag mismatch,
  while `v as integer` and Lua `3.0` entering every integer sink produce
  integer `3`;
- a truthy nonboolean fails an implicit strict `value -> boolean` projection,
  while `as boolean` and every Lua boolean sink produce `true`;
- `value as {integer}` and `value as Map<K,integer>` validate only the outer
  kind and perform no deep conversion; later typed reads remain strict;
- `value as boolean?` preserves nil and truthiness-converts every present
  value, with `is boolean?` reporting the same total acceptance; and
- `value as/is I` and every Lua Interface sink accept an existing exact `I`
  wrapper (or nil for `I?`) and reject a bare implementing record/union.

Add a negative invariant that neither an implicit `value -> T` adjustment nor
an Array/Map/callable gradual observation can contain or invoke a
`DynamicCoercionPlan`.

### 11.6 Callable matrix

Preserve the current arity/tail test table, but split its expected outcomes:

- shape-only adjustment cases;
- gradual `value` component cases;
- rejected ordinary coercion component cases;
- nested callable cases;
- optional/partial flexible projection cases; and
- exact-tag vs generic-path runtime cases.

Each accepted generic case needs:

- successful actual value;
- wrong value producing a clean gradual error;
- no accidental native fast path; and
- the same behavior after the function value is stored in Array/Map/record.

Exercise all three Titan-function entry roles explicitly:

- a static call and exact-tag first-class call both use the native entry;
- a genuine Lua call enters the coercive `CClosure.f` wrapper and retains the
  agreed numeric/truthiness conversions;
- a non-exact branded Titan call pushes the trailing strict LCF plus the
  original closure and rejects the same wrong runtime tags instead of
  coercing them;
- a non-Titan Lua closure, light C function, foreign C closure, and `__call`
  object remain on the ordinary Lua-call branch and are not mistaken for
  branded Titan closures;
- the generic caller strictly guards returned values from branded non-exact
  Titan closures, while results from non-Titan Lua callables use the same
  target `DynamicCoercionPlan` as `value as T` and other Lua boundaries;
- fixed missing/surplus arguments, typed variadic input, forwarded open runs,
  fixed/flexible results, finite demand, and `LUA_MULTRET` produce the same
  shape on strict and coercive stack entries while using different element
  policies;
- lambdas retain every capture, ordinary bound methods retain `self` at
  upvalue 4, and the original closure passed as `_fn` survives relocation and
  GC;
- source, DSO, static-provider, prefix-container, and standalone calls
  recognize the same fixed ABI Titan function-closure brand;
- the largest closure fitting `MAXUPVAL` with the strict trailer compiles, and
  the next capture count is rejected by the checker rather than failing in
  `lua_pushcclosure`; and
- backtraces attribute the strict adapter to the logical Titan callee without
  leaking a raw generated symbol.

Add paired witnesses where Lua accepts but Titan-generic rejects: an integral
float for an actual integer formal and a non-boolean for an actual boolean
formal. For results, contrast a branded Titan callable returning a float or
nonboolean through `value`—which the static Titan view rejects strictly—with a
non-Titan Lua callable returning the same payload, which dynamically coerces
it into the expected integer/boolean result.

For an Interface formal `I`, both stack-entry policies accept an existing
exact `I` wrapper and reject a bare implementing record/union. This row is
deliberately identical across strict and Lua modes because `R/U -> I` is a
checker-planned Titan coercion, not a Lua-boundary conversion.

### 11.7 Negative compiler invariants

Add tests that walk checked ASTs and generated plans:

- no accepted nonidentity edge lacks a plan;
- no open conversion is represented by an unannotated synthetic cast;
- every `has_tvalue_representation` type has a complete guard/store lowering;
- no gradual view contains a non-guardable leaf;
- coder modules do not call semantic relations;
- no per-type Array proxy metatable or global writer registry is emitted;
- no Array constructor omits the writer user value;
- no genuine-Lua non-nil `__newindex` path stores before writer conversion;
- no Titan Array read invokes or compares the Lua writer;
- no Array projection replaces the canonical proxy or writer;
- no typed Map read branches on or guesses write provenance;
- no non-exact branded Titan call invokes the coercive Lua entry;
- no genuine Lua call invokes the strict trailer;
- no foreign C closure is classified as Titan solely from upvalue count or
  trailer shape;
- no strict adapter loses the original closure passed as `_fn`;
- no branded Titan-generic argument/result uses `DynamicCoercionPlan`;
- no non-Titan Lua callable result uses a strict gradual guard;
- no implicit `value -> T` assignment or written `value as T` chooses policy
  merely from the common generated cast-node shape; and
- no Interface-targeted Lua sink synthesizes a wrapper from a bare
  record/union.

### 11.8 Adversarial-review and probe hygiene

Prior attempts at this compiler audit were interrupted when low-level examples
were described too broadly. Treat that as an operational constraint on review
wording and probe design, not as a reason to weaken semantic coverage.

- Begin each review request with the narrow scope: this is a type-relation
  audit for a prototype language/compiler, and every example is a compiler
  regression witness.
- Use **adversarial review** only in its compiler-testing sense: try minimal
  counterexamples against a proposed relation law or lowering invariant.
- Prefer type-system terms such as **relation witness**, **checked-error
  regression**, **guardability case**, and **FFI representation case**. Avoid
  unrelated security-oriented framing.
- Prove one relation or lowering property per minimal Titan program. Once a
  smaller witness establishes the result, do not make it more realistic or
  exercise unrelated downstream behavior.
- For raw-pointer/reifiability cases, prefer relation inspection, checked AST,
  generated-C inspection, and a benign harness that does not dereference the
  recovered address. The type-erasure result does not need a more invasive
  executable demonstration.
- Give reviewers the bounded case matrix from this plan. Do not ask parallel
  reviewers to invent progressively lower-level variants of the same case.
- Once a witness is accepted, encode it as an ordinary named spec so later
  verification can invoke the test without restating the entire example in a
  review prompt.
- If tooling interrupts a review, retain the completed evidence and resume
  with the source-level or generated-code proof. Do not repeatedly resubmit
  the same low-level wording or probe.

These constraints apply to task framing and unnecessary probe escalation.
They must not euphemize Titan semantics, weaken the expected diagnostics, or
remove any row from the relation/guard matrices.

## 12. Documentation work

The implementation change is user-visible and must update both manuals.

At minimum:

- `doc/language/types.md`;
- `doc/language/functions.md`;
- `doc/language/option-types.md`;
- `doc/language/arrays-maps.md`;
- `doc/language/lua-interop.md`;
- `doc/language/flexible-returns.md`;
- `doc/language/variadic-parameters.md`;
- `doc/language/ffi.md`;
- `doc/language/multi-module-libraries.md`;
- `doc/language/static-compiled-modules.md`;
- `doc/implementation/checker.md`;
- `doc/implementation/codegen-overview.md`;
- `doc/implementation/codegen-constructs.md`;
- `doc/implementation/dense-arrays.md`;
- `doc/implementation/lua-interop-internals.md`;
- `doc/implementation/flexible-returns.md`;
- `doc/implementation/variadic-parameters.md`;
- `doc/implementation/ffi-internals.md`;
- `doc/implementation/values-and-gc.md`;
- `doc/implementation/driver.md`;
- `doc/implementation/folder-modules.md`;
- `doc/implementation/multi-module-libraries.md`; and
- `doc/implementation/static-compiled-modules.md`.

Required terminology:

- **consistent**: the symmetric non-transitive gradual relation;
- **coercible**: a direct automatic conversion plan exists;
- **gradual view**: same compound value observed under a consistent static
  shape, with later guards;
- **callable adjustment**: directional arity/tail adaptation whose aligned
  components use gradual logic but not ordinary coercions;
- **dynamic coercion**: one target-directed conversion plan shared by written
  `value as/is T` and genuine Lua-to-Titan boundaries;
- **written-castable**: syntax explicitly requests a conversion/check;
- **comparable**: symmetric equality policy; and
- **guardable/reifiable**: the requested runtime type can actually be
  established later.

Publish one normative boundary matrix, referenced rather than independently
re-described by each chapter. It must distinguish:

- ordinary/direct Titan assignment and its explicit coercion plan;
- implicit `value -> T` gradual projection and strict Titan observation
  through every typed Array/Map read or branded callable gradual view;
- the one dynamic-coercion matrix shared by written `value as/is T`, genuine
  Lua function-formal/module-field/record-field/Array-element conversion, and
  non-Titan Lua callable results;
- exact native, strict Titan-generic, and coercive genuine-Lua function entry;
- exact-wrapper-only dynamic handling for Interface targets, with no
  record/union implementation discovery;
- Array nil deletion before element conversion;
- construction-time Array writer policy carried by the canonical proxy; and
- raw Lua Map mutation, which has no corresponding writer/provenance channel,
  followed by the same strict typed read regardless of origin.

The Array chapters must document:

- one shared per-state proxy metatable;
- backing key 0 to proxy, proxy user value 1 to backing, and proxy user value 2
  to the constructing module's writer closure;
- strict Titan reads versus coercive genuine-Lua writes;
- writer preservation through `value`, alternate views, imports, and nested
  boxing;
- module-local writer generation with no global registry, interning, or
  first-wins identity;
- the writer as Lua-write policy rather than a current-content type;
- the extra fixed per-Array user-value cost and GC edge to the writer/_mod;
- the standalone `{string}` argument writer;
- the ABI break from the old one-user-value proxy; and
- debug/C mutation of either private user value as programmer-responsible and
  outside the untrusted-code contract.

The function chapters must document:

- one canonical `CClosure` identity with `f` as the coercive Lua entry;
- module, exact type tag, native pointer, and fixed closure brand in upvalues
  0 through 3;
- capture/bound-receiver slots beginning at upvalue 4;
- the strict Titan-generic LCF as the final upvalue;
- exact native dispatch, branded non-exact strict dispatch, and non-Titan
  ordinary Lua dispatch;
- the hidden original-closure argument and strict entry's use of it as `_fn`;
- count-plus-raw-sentinel closure branding across modules/providers without
  registry access;
- strict result guards for branded non-exact Titan closures and dynamic result
  coercion for non-Titan Lua callables;
- the reduced-by-one capture budget and checked `MAXUPVAL` diagnostic;
- no companion adapter closure or entry-descriptor indirection; and
- debug/C mutation or extraction of private closure machinery as outside the
  untrusted-code contract.

Explicitly reconcile current documentation drift:

- `doc/language/arrays-maps.md` and
  `doc/implementation/dense-arrays.md` currently say Lua `__newindex` stores
  the incoming value verbatim;
- `doc/implementation/dense-arrays.md` and
  `doc/implementation/values-and-gc.md` describe exactly one proxy user value;
- `doc/language/lua-interop.md` contains conflicting claims about whether an
  integral Lua float is accepted for integer function arguments versus
  record/module writes;
- `doc/implementation/lua-interop-internals.md` describes the current
  `checkandget`/`checkandset` asymmetry as boundary behavior and conflates
  written `value as T`, Lua entry conversion, and container reads;
- `doc/language/expressions.md` and
  `doc/implementation/codegen-constructs.md` document broad scalar
  `value as/is T` behavior but currently make `boolean?` an accidental strict
  exception; preserve the broad written-cast semantics, recurse through
  Option, and do not "fix" casts by changing them to tag-only guards;
- bracket-cast folding in `coder.lua` must distinguish a written
  `value as T` annotation from a checker-inserted strict gradual projection
  rather than choosing policy from the common `Ast.ExpCast` shape;
- `doc/language/types.md`, `doc/language/lua-interop.md`, and their
  implementation chapters must distinguish shallow dynamic acceptance at a
  written/Lua boundary from strict interior Array/Map reads, and must classify
  non-Titan Lua callable results as incoming dynamic values;
- `doc/implementation/codegen-overview.md`,
  `doc/implementation/values-and-gc.md`, and
  `doc/implementation/index.md` describe only the three-upvalue function
  header and say non-exact Titan calls reuse the coercive Lua entry; and
- Interface documentation must not imply that a Lua-provided bare
  record/union is dynamically wrapped for an Interface target.

Remove claims that:

- `compatible` is both gradual consistency and directional callable
  assignment;
- C boundary conversions are consistency;
- ordinary component coercions lift through functions;
- every Array/Map element read already supports every boxable type; or
- lightuserdata can prove a raw C pointer's pointee type.

The ABI history, installation layout, provider compatibility, and generated
shim documentation must move coherently to ABI 0.20. Old ABI-0.19
one-user-value/no-strict-trailer providers must fail the normal ABI/metadata
checks rather than being accepted and misread by the new runtime.

### 12.1 Shared ABI-0.20 migration and Interface-cutover coordination

Treat this as a clean ABI cutover, not compatibility machinery:

- update `TITAN_VER` and the Array ABI history in `titan-runtime/titan.h`;
- update driver compiled-provider suffixes/default paths and
  `TITAN_PATH_0_20`;
- update Makefile, rockspec, bootstrap/provider installation paths, standard
  library publication, generated shims, installer validation/rollback, and
  workflow/cache ABI variables;
- regenerate/update DSO, archive, serialized-metadata, and ABI-mismatch
  fixtures across driver/static-provider/multi-module specs;
- rebuild every generated function closure with the fixed brand at upvalue 3,
  shifted capture/bound-receiver indices, and strict trailing LCF;
- prove an ABI-0.20 compiler/runtime rejects ABI-0.19 DSOs and archives before
  exchanging an Array or function value;
- update the clean-prefix CI proof to require `lib/titan/0.20/?.so` and reject
  the active 0.19 template;
- on a relation-only review head, rebuild the existing nine-module provider
  and shims only as clean non-published validation; on the final coordinated
  tree, rebuild and validate the Interface plan's ten modules/keys/shims and
  eleven openers under the same ABI 0.20; and
- update `README.md`, `AGENTS.md`, and both manuals so commands, paths, and
  ownership statements describe the active ABI consistently.

The relation/Array/function repair and Interfaces jointly define ABI 0.20.
They may be separate review units, but neither PR's intermediate
generated/runtime layout is a separately published ABI. If the relation PR
lands first, that PR owns the one mechanical 0.19-to-0.20 marker/path advance,
but ABI-0.20 release/publication remains gated on the Interface PR. The
Interface PR inherits and completes that version rather than advancing it
again. Provider tests must rebuild rather than mix artifacts from the two
heads. The completed cutover rejects ABI 0.19 and contains both layouts without
a second version advance.

`.agents/plans/interfaces-v1.md` has been reconciled with this design: its
concrete-to-Interface edge is one direct outer coercion; its private
structural-satisfaction predicate is explicitly not subtyping or consistency;
and method matching uses `callable_adjustment` with ordinary component
coercions disabled. In particular, neither ordinary `() -> R` to `() -> I`
assignment nor a concrete method result `R` for a required Interface result
`I` is admitted.

## 13. Implementation phases

### Phase 0 — freeze semantics and add failing regressions

1. Commit the maintainer laws at the top of the relation specs.
2. Add the Section 2 counterexamples before refactoring, following the bounded
   review/probe protocol in Section 11.8.
3. Freeze strict gradual guards for implicit `value -> T`, every typed
   Array/Map read, and branded Titan-generic calls separately from the one
   `DynamicCoercionPlan` matrix used by written `value as/is T`, Lua formals,
   record/module fields, Array writers, and non-Titan Lua callable results.
4. Freeze the shared-metatable/two-user-value Array layout, module-local writer
   generation, nil-deletion rule, construction-policy semantics, and
   debug-library scope.
5. Freeze the function entry split: native exact, strict branded
   Titan-generic with a trailing LCF and hidden original closure, and coercive
   genuine-Lua; freeze the four-slot header with the opaque brand in slot 3,
   shift captures/receiver to slot 4, and exclude private debug/C header
   mutation.
6. Record that an Interface `DynamicCoercionPlan` accepts only an existing exact
   wrapper, never a bare implementing record/union.
7. Record that the Array writer design does not imply coercive raw-Map writes
   and that every typed Map read remains strict regardless of origin.
8. Choose the raw-pointer policy from Section 8.
9. Snapshot the intended callable shape matrix with component coercions marked
   rejected.

Gate:

- every current defect reproduces against checkout modules;
- every intended change has an explicit expected result; and
- there is no unresolved distinction among direct coercion, strict gradual
  guard, and the shared explicit-value/Lua dynamic coercion.

### Phase 1 — normalize and introduce new relations

1. Add cycle-safe `normalize`.
2. Add pure symmetric `consistent`.
3. Add plan-producing `coercion` and `written_cast`.
4. Add target-directed `dynamic_coercion`; make the `value` branch of
   `written_cast` and every genuine-Lua sink consume it.
5. Add `has_sound_gradual_guard`.
6. Keep old functions as temporary wrappers only.

Gate:

- relation truth tables/laws pass;
- `consistent` has no dependency on coercion, dynamic coercion, or written
  cast; and
- no caller behavior has migrated accidentally.

### Phase 2 — callable and assignment plans

1. Implement directional `callable_adjustment`.
2. Move shape-specific nil/flex behavior into named actions.
3. Implement `assignment_adjustment`.
4. Reverse old tests that admitted numeric/Option/interface coercions inside
   callable components.
5. Add nested callable tests.

Gate:

- all callable shape cases are classified;
- `() -> T` to `() -> T?` is rejected;
- exact tags remain the only fast path; and
- wrong gradual values fail cleanly on the generic path.

### Phase 3 — checker elaboration

1. Migrate fixed sinks to assignment plans.
2. Migrate open sinks and positional constructors to stored element plans.
3. Route equality and written casts to their own classifiers; the `value`
   written-cast branch embeds the canonical dynamic plan.
4. Attach C lifetime/provenance metadata to C coercion plans.
5. Implement whole-slot Option-to-`TValue` boxing.
6. Record the final context-adjusted element type and dynamic writer plan
   for every Array construction.
7. Inventory distinct constructed Array types per module for writer-slot
   emission.
8. Attach strict argument/result guard plans to branded non-exact callable
   sites and dynamic result plans to non-Titan Lua-call branches; the coder
   must not rediscover policy from runtime entry choice.

Gate:

- every accepted nonidentity edge is explicit in checked AST/annotations;
- coder-side relation discovery is unnecessary; and
- checker regressions pass.

### Phase 4 — coder guards and open runs

1. Split strict observation guards from dynamic/direct-coercion helpers.
2. Generate native-result, boxed-store, and non-raising predicate forms from
   one `DynamicCoercionPlan` matrix, and use them consistently for written
   casts and every genuine Lua boundary.
3. When the work is split, make this relation PR own the single mechanical
   ABI 0.19-to-0.20 advance; migrate Array proxy/runtime helpers to two user
   values while retaining the shared proxy metatable.
4. Emit/cache module-local writer closures, attach them at every fixed, empty,
   open, nested, and imported-type Array construction, and update standalone
   `{string}` argument construction.
5. Make shared Array `__newindex` validate the index, handle nil deletion, and
   invoke the carried writer before any mutation; keep every Titan read/proxy
   guard independent of the writer slot.
6. Refactor stack-entry generation into coercive and strict policies; insert
   the fixed brand at upvalue 3, append the strict LCF to every Titan function
   closure, and route non-exact branded calls through the LCF with the original
   closure hidden on the stack.
7. Shift lambda capture and bound-receiver indices to begin at upvalue 4,
   enforce the reduced `MAXUPVAL` capture budget in the checker, and extend
   bound/coroutine/uv/Interface call paths.
8. Complete C scalar/pointer/raw-`TValue` Option-present guards and Array
   writer lowerings.
9. Make all open-run sites consume their stored plan.
10. Remove synthetic naked `Ast.ExpCast` construction.
11. Enforce the raw-pointer policy.
12. Add completeness assertions.

Gate:

- all Section 2 programs either run/raise as specified or are rejected;
- no checked program reaches `invalid type`/`invalid node tag`;
- the complete Array/Map guard matrix passes;
- every typed Map read uses the strict guard regardless of whether Titan or
  Lua wrote the stored slot;
- written `value as/is T`, Lua function arguments, record/module writes, Array
  writes, and non-Titan Lua callable results pass the dynamic-coercion parity
  matrix;
- every Array construction installs a rooted writer and every genuine-Lua
  non-nil write uses it without changing the hot shared-metatable read path;
- every non-exact branded Titan function call uses strict argument/result
  guards without entering the coercive Lua wrapper, while non-Titan callables
  remain ordinary Lua calls whose results use the shared dynamic coercion;
- old/new Array proxy layouts fail the ABI boundary cleanly; and
- generated C contains no unplanned semantic conversion.

### Phase 5 — retire old relations, docs, and full validation

1. Migrate every remaining caller.
2. Remove `types.compatible`, old boolean-only written-cast logic, and
   duplicated `checkandget`/`checkandset` policy switches.
3. Update both manuals, including the normative boundary matrix and all
   one-user-value/verbatim-write, two-entry function, explicit-cast/Option,
   Map-read, and Interface Lua-discovery drift.
4. Verify the already reconciled Interfaces plan remains synchronized with
   the final relation APIs and tests.
5. Update ABI history, 0.20 paths, provider/metadata fixtures, installer/rockspec,
   generated shims, CI cache/layout checks, and repository instructions for
   ABI 0.20.
6. Run targeted and complete validation.
7. Perform independent semantic, generated-C, runtime-layout, and
   documentation reviews.

Only then should Interface implementation proceed on the repaired central
relations.

## 14. Verification commands

From the repository root with a current isolated prefix:

```sh
busted spec/types_spec.lua
busted spec/checker/type_relations_soundness_spec.lua
busted spec/coder/type_relations_soundness_spec.lua
busted spec/abi_spec.lua
busted spec/dense_array_runtime_spec.lua
busted spec/checker/dense_arrays_spec.lua
busted spec/coder/dense_arrays_spec.lua
busted spec/checker/flexible_returns_schema_spec.lua
busted spec/coder/flexible_returns_spec.lua
busted spec/coder/variadic_spec.lua
busted spec/coder/first_class_functions_spec.lua
busted spec/coder/contextual_value_calls_spec.lua
busted spec/coder/closures_spec.lua
busted spec/coder/bound_methods_spec.lua
busted spec/checker/c_ffi_spec.lua
busted spec/coder/c_ffi_spec.lua
busted spec/checker/type_tests_spec.lua
busted spec/coder/type_tests_spec.lua
busted spec/driver_spec.lua
busted spec/checker/static_compiled_modules_spec.lua
busted spec/coder/static_compiled_modules_spec.lua
busted spec/coder/multi_module_libraries_spec.lua
busted spec/rockspec_spec.lua
busted spec/stdlib_installer_spec.lua
make test
bash spec/support/ci_test_groups.sh compiler
bash spec/support/ci_test_groups.sh libraries
git diff --check
```

Compiler/language relation cases belong in the covered compiler group.
Standard-library behavior remains outside LuaCov.

The published change requires normal exact-head Linux evidence. The maintainer
has explicitly waived the manual macOS dispatch for this relation/ABI review
unit; record that waiver in the handoff rather than treating macOS as a failed
or missing check.

Local branch evidence on 2026-07-30:

- `make test`: 2,576 successes, zero failures/errors/pending;
- `bash spec/support/ci_test_groups.sh compiler`: exit 0;
- LuaCov: 89.75% overall, including 92.69% for `checker.lua`, 94.45% for
  `coder.lua`, and 92.99% for `types.lua`;
- `bash spec/support/ci_test_groups.sh libraries`: exit 0 across all 23
  native/runtime and standard-library files;
- focused source/DSO/archive relation suites and all independent reviews:
  green; and
- `git diff --check` and Lua 5.5 parsing of every changed/new Lua file: green.

This evidence is deliberately labeled local rather than exact-head: the latter
is recorded only after the reviewed commit is pushed and the Linux workflow
finishes for that exact SHA.

Because this is also the ABI-0.20 cutover, the Linux producer evidence must
include the clean-prefix/path assertion, ABI-0.19 DSO/archive rejection,
canonical 0.20 standard-provider publication, standalone-main writer case,
three-path function-entry/provider cases, and packaging/install rollback
suites. Do not treat `make test` alone as evidence that old/new Array proxies
or function closures cannot mix. Final release evidence is taken only after
the coordinated Interface changes are also present in ABI 0.20.

## 15. Completion criteria

The repair is complete only when:

- `consistent` is pure, reflexive, symmetric, and demonstrably
  non-transitive;
- transparent aliases are normalized rather than treated as graph edges;
- no numeric/Option/C/interface/written conversion is a consistency leaf;
- no general coercion recurses through Array, Map, or Function;
- `T` and `T?` are inconsistent, and `() -> T` cannot become
  `() -> T?` through callable assignment;
- callable shape adjustment compares aligned components directly and records a
  complete directional plan;
- sequential non-`value` bridges from Section 2 are rejected;
- intended `value` bridges retain clean guarded behavior;
- every Array/Map-storable type has complete store/read/Option/Lua/open
  lowering;
- gradual guards are not accidentally ordinary numeric/truthiness coercions;
- every Array proxy retains the one shared metatable, canonical backing cycle,
  and exactly two user values in the specified backing/writer order;
- every Array construction installs the module-local writer selected from its
  final context-adjusted element type, including open/nested construction and
  standalone `{string}` arguments;
- `value`, alternate views, boxing, imports, and returns preserve the same
  proxy and writer; no static view compares or replaces writer identity;
- every genuine-Lua non-nil Array write passes through the carried coercive
  writer, while nil deletion bypasses element conversion;
- every typed Titan Array read uses the strict gradual guard and never invokes
  the Lua writer;
- every typed Titan Map read uses the same strict target guard regardless of
  whether the slot was written through Titan or raw Lua, with no provenance
  branch;
- Titan writes bypass the writer and therefore do not falsely establish a
  construction-type heap invariant;
- nested raw/proxy normalization preserves the inner Array's writer and uses
  direct shared-metatable pointer equality on the read path;
- a failed Lua conversion leaves Array capacity, length, and contents
  unchanged;
- there is no global Array-writer registry, first-wins protocol, cross-module
  writer interning, or defensive correctness promise after debug user-value
  corruption;
- one normative `DynamicCoercionPlan` matrix agrees across written
  `value as/is T`, Lua function formals, record/module writes, Array writers,
  and results entering Titan from non-Titan Lua callables;
- integral-float/integer, numeric/float, truthiness/boolean, recursive Option,
  nominal, container, Function, C, and Interface parity rows all pass, while
  the corresponding implicit `value -> T` and typed container observations
  remain strict;
- a dynamic Interface target accepts nil where optional or an existing exact
  wrapper, but never constructs one from a bare implementing record/union;
- every Titan function closure retains its native pointer at upvalue 2,
  fixed brand at upvalue 3, captures/bound receiver beginning at upvalue 4,
  and a strict Titan-generic LCF in the final upvalue;
- static/exact Titan calls use the native entry, non-exact branded Titan calls
  use strict argument/result guards through the trailer, and genuine Lua calls
  alone use the coercive `CClosure.f` entry; non-Titan Lua callable results use
  dynamic result coercion;
- after an exact-tag mismatch, the five-upvalue guard and raw fixed-brand
  comparison distinguish Titan closures without registry access, and the
  strict adapter retains the hidden original closure as `_fn`;
- fixed, variadic, flexible, bound, lambda, DSO/archive, and maximum-capture
  cases preserve their calling/result/GC contracts under the three entries;
- the ABI bump prevents one-user-value and two-user-value Array
  implementations and old/new function-closure layouts from mixing;
- raw C pointer behavior has an explicit enforced policy;
- every open run consumes a checker plan;
- equality is operand-order independent;
- dynamic/written-only operations cannot leak into implicit assignment,
  structural consistency, branded Titan-generic, or typed Array/Map read paths;
- no checked counterexample reaches an internal compiler error;
- both manuals match implementation;
- targeted suites, `make test`, and CI groups pass; and
- the Interfaces plan consumes `coercion` and `callable_adjustment` without a
  private compatibility variant.

## 16. Principal risks

1. **Renaming without separation.** Calling current `compatible`
   `consistent` would preserve the defect.
2. **Overcorrecting callable shape.** Removing scalar coercions must not
   accidentally remove intentional ignored-input/result and tail adjustment.
3. **Treating consistency as an operation.** `integer ~ value` still needs a
   concrete injection/projection plan.
4. **Using dynamic coercion at a strict observation.** Shared
   truthiness/numeric convenience is intentional for written `value as T` and
   genuine Lua boundaries, but is broader than implicit projection,
   Array/Map reads, and branded Titan-generic guards.
5. **Assuming boxable means reifiable.** Lightuserdata retains address bits,
   not a C pointee type.
6. **Partial guard coverage.** The current C-valued Array read crash proves
   hand-maintained type switches drift.
7. **Coder rediscovery.** Any coder relation query or synthetic semantic cast
   can recreate the open-run failures.
8. **Forgetting sequential views.** A non-transitive relation may be applied
   more than once by a program; every intended dynamic bridge needs guards,
   while unintended conversion bridges must be absent.
9. **Interface-specific shortcuts.** Record/union-to-Interface remains one
   direct outer coercion; it must not leak into structural recursion.
10. **Review interruption from ambiguous framing.** Broad or unnecessarily
    low-level descriptions can interrupt an otherwise ordinary compiler
    review. Keep the prototype/type-system scope explicit, use the bounded
    witnesses, and stop probe escalation once the semantic claim is proven.
11. **Treating the writer as a type tag.** The closure controls genuine-Lua
    writes only; it neither proves current contents nor participates in a
    gradual view check.
12. **Regressing nested-read cost.** Titan Array guards must retain direct
    shared-metatable pointer equality and must not inspect the writer on every
    inner read from `{{value}}`.
13. **Missing a construction path.** Empty, open, nested, variadic/flexible,
    standalone-argument, and future synthesized constructors all need a
    writer selected from the final constructed element type.
14. **Writer lifetime or partial mutation.** The proxy must trace the closure
    and captured `_mod`; conversion failure or stack relocation must not stale
    the receiver/backing or commit capacity/length/content changes.
15. **Reintroducing global identity.** A registry, first-wins protocol,
    per-type proxy metatable, or writer comparison would add machinery the
    semantics do not require and recreate the alternate-view problem.
16. **Nil/truthiness conflation.** Array nil is deletion and must be handled
    before a boolean or other genuine-Lua element conversion.
17. **Conflating Arrays and Maps.** The proxy makes Array Lua writes
    interceptable; raw Map tables still have no corresponding provenance or
    writer, so every typed Map read must stay strict.
18. **Overpromising debug robustness.** The trusted invariant excludes
    programmer mutation/extraction of private Array/Interface user values and
    function-closure upvalues through the debug API.
19. **ABI/documentation drift.** Any remaining one-user-value, verbatim-write,
    old-path, or old-provider claim can make otherwise correct compiler/runtime
    pieces unsafe to combine.
20. **Using the Lua entry for Titan-generic calls.** Reusing `CClosure.f`
    silently restores numeric/truthiness coercions inside gradual callable
    consistency.
21. **Recognizing non-exact closures by shape.** After the likely exact
    static-tag comparison fails, require at least five upvalues and compare
    raw upvalue 3 with the fixed opaque Titan-function sentinel before reading
    non-exact Titan-private slots. Do not restore the reverse-tag registry or
    add other slot-shape checks to this classifier.
22. **Losing the original closure.** The strict adapter must receive, root, and
    pass the original closure as `_fn`, or lambdas and bound methods read the
    wrong captures.
23. **Hidden-argument accounting.** Missing/surplus, variadic, flexible-result,
    stack-capacity, and error-slot arithmetic must consistently exclude the
    hidden closure argument.
24. **Capture-limit regression.** The LCF trailer consumes one `MAXUPVAL` slot;
    reject the first oversized capture set in the checker rather than at the
    Lua API.
25. **Dynamic Interface discovery.** The target Interface is known, but a
    dynamic value does not carry the checker-proven concrete implementation
    mapping. Its shared dynamic plan accepts only an existing exact wrapper.
26. **Duplicated dynamic matrices.** If function-entry reads, field stores,
    Array writers, non-Titan Lua results, and written casts keep separate
    switches, numeric/truthiness/Option behavior will drift again. Generate all
    lowering forms from one `DynamicCoercionPlan`.
27. **Narrowing explicit casts while repairing reads.** Existing broad
    `value as/is T` behavior is intentional and shares the Lua-boundary plan;
    only implicit/gradual observations become strict.
28. **Treating all generic results alike.** Branded non-exact Titan results are
    strict gradual observations, while non-Titan Lua callable results cross a
    dynamic boundary and must use the canonical coercion.
