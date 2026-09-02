# Interfaces

Interfaces add one nominal, type-only declaration and one run-time wrapper
representation. A record or union does not acquire an Interface supertype.
Instead, the checker may authorize one direct concrete-to-Interface coercion
at a statically known use site, and the coder lowers that coercion to a fresh
wrapper containing the concrete receiver, its owning module, an ordered method
table, and declaration-order field snapshots. Code generation also advertises every emitted pair on the
concrete metatable so later strict/dynamic Interface observations can construct
that same wrapper after type erasure. ABI 2 includes the serialized Interface
schema and wrapper user-value count for fields; dynamic discovery adds no
new relation.

The language-visible contract is in
[Interfaces](../language/interfaces.md). This chapter describes the parser,
type descriptors, checker plans, generated representation, dispatch paths,
loader contract, and ABI.

## Frontend representation

`interface` is a Titan keyword, but the C FFI's contextual identifier
positions still accept the spelling as a C typedef, field, module member, or
prototype parameter.

The parser admits only a top-level, non-local, nonempty declaration whose body
may mix fields and bodyless methods. It emits:

```lua
Ast.TopLevelInterface(loc, name, members, fields, methods, typeparams)
Ast.Decl(loc, name, type, false, true) -- Interface field
Ast.InterfaceMethod(loc, name, params, rettypes, flexrettype)
```

`members` retains source order, while `fields` and `methods` are the dense
ordered projections consumed by checking. Interface fields use `name: T` and
are represented as exact-const declarations; the record-only optional-name
shorthand is not admitted. An `InterfaceMethod` has no body. Its parameter list uses the ordinary
fixed/named and optional typed-tail representation; its result list likewise
uses the existing fixed and flexible-result nodes. Parser-specific diagnostics
cover local or nested declarations, an empty body, local members, duplicate or
cross-kind names, missing names/parentheses/types, unexpected members, and a
missing final `end`.

The checked descriptors are:

```lua
Type.Interface(name, fields, methods, scope, typeparams)
Type.Field(fqtn, name, type, index, true)
Type.Method(fqtn, name, params, rettypes,
            varargtype, flexrettype, paramnames)
```

`name` and `fqtn` are the same fully qualified Interface identity.
`Interface.fields` and `Interface.methods` are independent hybrid ordered lists
and name maps. Numeric entries retain declaration order within their kind,
while `list[name]` points to the same descriptor. The public constructor accepts
only two dense numeric lists whose combined length is nonzero, rejects
duplicate and cross-kind names and mismatched owners, requires canonical
zero-based field indices and `isconst == true`, and derives the string keys
itself. `types.validate_interface_descriptor` rechecks those projections after
construction.

Field and method order are ABI-significant. Serialization writes both numeric
lists in order and reconstructs the name maps through `types.Interface`; it
does not sort either kind by name.

## Declaration staging and publication

Interfaces share the type-only namespace with aliases, records, and unions.
The checker precollects Interface and alias spellings before signature
checking. A record or union owns both the value and type spelling and wins a
conflict regardless of source order; Interfaces and aliases otherwise retain
the existing first-declaration-wins policy.

The signature pass runs imports and aliases first, then record/union
descriptors, then Interfaces. This makes every nominal used in a member
signature available without changing the AST's source order. Checking an
Interface:

1. reserves the complete shared member namespace in source order;
2. builds each `Type.Field` in field order and each `Type.Method` in method
   order;
3. records fixed parameter names for named calls;
4. rejects duplicate/cross-kind member names and duplicate parameter names;
5. checks every field and callable component with the ordinary type validator;
6. rejects nonexportable C descriptors and local nominal types; and
7. registers the completed descriptor under its fully qualified name in
   `types.registry`.

Interfaces have no value declaration, constructor, module accessor, or public
module-userdata slot. `checker.makemoduletype` publishes them directly in
`Type.Module.type_members`, alongside type aliases. Imported module
registration installs all direct Interface descriptors before traversing their
field and method signatures, so mutually referring Interfaces and transitive
nominal owners are available while recovering a compiled module.

## Direct structural satisfaction

`types.interface_implementation(concrete, interface, policy)` is a dedicated
predicate, not a branch of gradual consistency or a subtyping relation. The
checker supplies the cast-site module and member-visibility callback in
`policy`; the generic relation layer does not resolve nominal descriptors or
decide visibility.

The predicate first rejects a union when the Interface field list is nonempty.
It then scans both ordered projections. For each field slot it requires:

- a same-named visible `Type.Field` on the concrete record;
- no collision with a method or static;
- `isconst == true`; and
- an ordinary automatic assignment plan from the concrete field type to the
  required Interface field type.

For each method slot it requires:

- a same-named `Type.Method` on the concrete record or union;
- no collision with a field, record/union function, or union variant;
- visibility from the conversion site; and
- directional callable adjustment from the concrete method's self-removed
  function type to the Interface method's self-removed function type.

`types.method_function_type` projects both methods to ordinary
`Type.Function` shapes and leaves declaration-only parameter names out of
identity and adjustment. Aligned components may be exact, gradually
consistent, or nested callable adjustments. A wholly missing concrete result
may use `nil_fill_result` only when the Interface result passes
`accepts_missing_nil`; the action has no source component and source-flex
projection takes precedence. `component_adjustment` does not consult ordinary
coercion, so numeric, Option, C, and concrete-to-Interface coercions do not lift
through a method signature.

The result retains independent ordered field and method mappings. A field
mapping freezes the source/target indices, descriptors, types, and assignment
plan; a method mapping retains:

```text
slot, name, required Interface Method, concrete Method,
source function shape, target function shape, adjustment, exactness
```

A failure identifies the first failing required field in field order or, after
all fields pass, the first failing method in method order. It classifies the
problem as missing, wrong-kind collision, inaccessible, mutable field,
incompatible field type, or incompatible callable.

The scalar coercion path sees only `Type.Nominal` endpoints. At an ordinary
target-typed use site, the checker passes a policy callback to
`types.coercion`; that callback resolves the concrete and Interface
descriptors and authorizes only the direct outer `interface_wrapper` plan.
Options use the explicitly supported outer `option_wrap`, `option_force`, or
`option_map` compositions around that scalar plan.

`types.consistent` has no concrete/Interface or Interface/Interface structural
case. Its Array, Map, Option, and Function recursion therefore cannot turn
Interface satisfaction into a compound relation. Distinct nominal Interfaces
remain unrelated. This separation is what prevents an accepted `R -> I`
coercion from implying `{R} -> {I}` or `() -> R` to `() -> I`.

## Frozen conversion and adapter plans

The checker attaches `_interface_conversion` to every accepted wrapper
construction. The annotation retains the exact concrete and Interface
descriptors, their nominal value types, the independent ordered field/method
mappings, pair exactness, and any outer Option operation. It is the coder's authority to allocate; the
coder does not rerun structural matching.

Each field mapping freezes its ordinary assignment adjustment before code
generation. Unlike method-component matching, a field's scalar adjustment may
itself construct an Interface or callable wrapper. Concrete/Interface pair
inventory therefore runs a deterministic growing worklist to a fixpoint over
all nested field adjustments before bytewise pair sorting and emission. The
emitter never discovers or appends a pair while iterating an already frozen
inventory.

An exact mapping needs no adapter. For a non-exact mapping, the generalized
freezer supplies the same closed, relation-free callable action subgraph used
by first-class closure adjustments. `make_interface_adapter` then wraps that
subgraph in a distinct `interface_method_adapter` with Interface-specific hidden
operands, minimal lifetime roots, genuine stack rebases, lifetime labels, and
method invocation backend. The shared callable operations are limited to:

- identity;
- gradual injection;
- a gradual guard whose timing is frozen as either an immediate projection
  (including the corresponding Option case) or a representation-preserving
  delayed Array/Map observation;
- a nested frozen callable adjustment; and
- the ordinary argument/result run actions for fixed slots, missing-argument
  nil fill, `nil_fill_result`, ignored slots, typed tails, flexible tails, and
  hidden surplus results.

The checker explicitly rejects a nested concrete-to-Interface conversion in
this *method-component* graph. Field adjustments use the separate frozen path
above. The Interface adapter records a minimal fixed/open root inventory:
native input-source inventories are empty, fresh nested callable destinations
get immediate roots, and every live GC-bearing fixed/open native source result
is rooted immediately after return. Its rebase ledger includes only operations
that can really move the stack plus the concrete native call; nested callable
allocation is not a rebase point. The coder validates both closed records and
their dense lists, rechecks types and action sequence against the two method
descriptors, and never calls a type relation while
emitting the adapter. The shared conversion-action emitter is parameterized by
invocation: this Interface path calls a known method with concrete self, while a
closure wrapper recovers and calls its penultimate immediate source closure. See
[Closure adjustment wrappers](closure-adjustment-wrappers.md#one-frozen-callableadapterplan).

The existing frozen immediate nominal guard is already a possible rebase
point. Code generation now uses that allowance when an Interface guard invokes
a witness; no checker relation, adapter-plan field, or root inventory changes.

For a finite flexible-result request, the adapter first consumes any surplus
fixed concrete results before asking the concrete flexible tail for more.
Discarded concrete tail values therefore remain unevaluated by the gradual
guard; `LUA_MULTRET` still forwards an open demand unchanged.

Concrete/Interface pair obligations are collected by that worklist only in a
translation unit that constructs the wrapper. Their key is the fully qualified
concrete name followed by the fully qualified Interface name. The list is
sorted bytewise before emission, and private adapter symbols encode both names
injectively plus the declaration-order slot. Each pair also receives one
deterministic private wrapper-witness symbol in the emitting
module/concrete/Interface native hierarchy. Allocation-free static `is` tests
validate their frozen mapping without registering a pair, so only a real
wrapper construction causes a pair to be advertised and discovery order does
not affect generated identities.

## Wrapper representation

Every Interface value is a full `Udata` with:

- opaque payload length
  `method_count * sizeof(TitanInterfaceMethod)`;
- exactly `2 + field_count` traced user values;
- the canonical metatable for the fully qualified Interface; and
- no mutable state.

The layout is:

```text
payload[0 .. method_count-1]  copied native method entries
user value 0                  concrete type's owning module Udata
user value 1                  concrete record/union Udata
user value 2 + i              target-typed snapshot of Interface field i
metatable                     exact Interface identity
```

`TitanInterfaceMethod` is a function-pointer storage type declared in
`titan-runtime/titan.h`. Generated code converts concrete or adapter entries
to and from that storage through `titan_cast_func`; the payload never contains
data pointers and is not a GC graph.

Method-only wrappers therefore retain the old two-user-value layout.
Field-only wrappers request a zero-byte payload; code generation does not emit
a zero-length C pair array or call `memcpy` with one.

One process-static pair array is emitted per used concrete/Interface pair that
has at least one method.
After imported native symbols have been recovered, initialization fills each
slot with either the exact concrete method or the private adjustment entry.
This happens on both module-initialization branches and before a user module
initializer can construct a wrapper. Each method-bearing wrapper copies the
complete array with `memcpy`; pair arrays and wrappers are not interned.

The same pair emits one private `lua_CFunction` witness. It captures the
emitting module in upvalue 0 and receives a bare concrete Udata in stack slot
1. Using Lua internals rather than the public Lua API, it invokes the pair's
shared allocator for `2 + field_count` user values, replaces slot 1 with the
result, publishes the target Interface metatable, concrete-owner module,
original concrete self, and adjusted field snapshots with ordinary barriers,
copies a nonempty filled pair array, and returns one value. The incoming
argument remains traced through allocation. Field adjustments that allocate
use traced temporaries and restored stack offsets; no stale `StkId` spans a
possible rebase.

Wrapper construction evaluates the concrete value exactly once into an untraced
C temporary, relying on its ordinary allocation/result/semantic/VM provenance.
It resolves the concrete-owner module, obtains the Interface metatable from the
emitting module's cache, and invokes the same per-pair full-userdata allocator.
This path conservatively treats that allocation as a stack-rebase point: it
saves `_base_off`, restores `_base` immediately after the call, and publishes
the new Udata to its own initial root before any later allocation or traced-edge
publication. Lua's collector does not move heap objects, while saved offsets
keep the destination root address valid if the stack array moves. It then:

1. installs the Interface metatable;
2. stores the concrete module in user value 0 and applies the Udata barrier;
3. stores the concrete value in user value 1 and applies the Udata barrier;
4. evaluates every concrete field exactly once in Interface field order,
   applies its checker-frozen adjustment, stores it in user value `2 + i`, and
   applies a barrier for each collectable snapshot; and
5. copies the ordered pair array into the opaque payload when methods exist.

The wrapper stays rooted before the first field adjustment. Nested Interface or
callable construction can allocate and rebase the stack, so sources,
destinations, and wrapper homes are recovered from offsets after each such
operation. The allocator checks the runtime integer bound for
`2 + field_count` before calling `luaS_newudata`.

The concrete module is `_mod` when the concrete type belongs to the current
module. Otherwise the translation unit retains or recovers the concrete
owner's module Udata in a private module slot. It never substitutes the
Interface owner or emitting module.

During initialization, after nominal metatables have been recovered and the
pair array has been filled, generated code raw-reads the concrete metatable at
the target Interface metatable key. A nil entry is replaced with a C closure
for the witness, capturing the current emitting module; any non-nil entry is
left untouched. Registration is repeated for every Lua state and on either
initialization path, while equivalent modules in one state obey first-writer
wins. The ordinary initialization code may use the Lua API; only the generated
witness body itself is restricted to direct stack manipulation.

## Native entry ABI and adjustment entries

A concrete method's native ABI is the ordinary method ABI:

```text
result method(
    lua_State *L,
    Udata *concrete_mod,
    CClosure *fn,
    Udata *concrete_self,
    fixed arguments,
    optional typed-input descriptor and start,
    secondary-result pointers,
    optional flexible-output descriptor and budget)
```

An exact Interface slot points directly at that entry. An adjustment slot
points at a private function with the Interface method's native signature.
The adapter receives the same hidden operands, but its invariant is fixed:

- `_mod` is user value 0, the concrete type's owning module;
- `_fn` is `NULL`;
- `_self` is user value 1, the original concrete value.

The adapter converts Interface arguments into the concrete callable's shape,
calls the concrete method with those hidden operands unchanged, and converts
the concrete results into the Interface shape. A `nil_fill_result` initializes
the first C return or the appropriate later out-parameter without reading a
concrete result. The translation unit that emits the adapter is irrelevant to
`_mod` provenance. These steps share the closure adapter's action/root/rebase
engine; only this known-method invocation differs.

Open input and result runs use the existing typed descriptor ABI and the
`TITAN_VARARG_MAX` bound. Raw descriptors and C buffers are never roots. Native
fixed/static arguments and forwarded open values stay in C and borrow their
existing allocation/result/semantic/VM provenance; the adapter creates no input
source roots. Converted argument or result destinations receive fixed/range
roots only when an action allocates a fresh nested wrapper. After the concrete
native call and rebase, every live GC-bearing fixed/open concrete source result
is rooted immediately, even for identity conversion. A general open conversion
outside this graph applies the same immediate-root rule to a newly allocated
Interface value.

If the shared frozen graph can allocate a nested callable view, the synthesized
native adapter polls the collector at entry before reserving stack space or
establishing `_base`; no poll enters a fresh closure's construction window.

The adapter reserves only its actually rooted range. Type identity setup resolves
nominal and owned-C metatables and mutable/const Array metatables directly from the
adapter's module uservalue slots `_mod->uv[slot]` without any Lua registry lookup.
Because `_mod` is the module where the interface cast occurred (which owns the adapter
and has seen both the interface and the concrete types in scope), all required type
identities are available as static module uservalue slots.

Adapters resolve any Array, nominal, or owned-C identities needed by immediate
guards from `_mod->uv[slot]`. When calling the concrete method, the adapter forwards
`concrete_mod` (the concrete type's owning module, resolved from `_mod` or imported
module uservalue slots) and `_self` (the unwrapped concrete record or union).

## Four dispatch paths

Interface field access does not dispatch through the method payload. A native
read validates the exact `2 + field_count` user-value shape, loads user value
`2 + target_index`, and unboxes it under the required target type. Lua
`__index` distinguishes a declared field from a method name and boxes the same
snapshot slot. Both paths read the conversion-time value; all assignment paths
classify an Interface field as const and reject the write.

### Direct Titan method calls

For `wrapper:method(...)`, generated code evaluates the wrapper once into an
untraced C temporary before later argument effects. It creates no native input
root. It checks that the payload contains exactly the Interface's method count
and that the wrapper has exactly `2 + field_count` user values, loads the
declaration-order slot, casts it to the method signature, and calls it with:

```text
wrapper.user_value_0, NULL, wrapper.user_value_1, arguments...
```

The common path is one indexed payload load plus the ordinary native call.
Malformed length or a null slot raises an internal Interface error.

### Genuine Lua method calls

The Interface owner creates a generic Lua entry for every method. Its
metatable method map stores one closure per public method, capturing the
Interface owner's module so argument and result conversion uses the
Interface signature's identities.

The entry dynamically converts argument 1 through the exact-or-witnessed
Interface path, applies the ordinary Lua-boundary dynamic plans to the declared
arguments, loads the resulting wrapper slot, then invokes the selected payload
with the concrete module and concrete self. Returning through the entry boxes
results for Lua. A bare record or union reaches the payload only after a
registered witness has constructed that wrapper.

### Strict Titan generic calls

A bound Interface method starts as an ordinary branded Titan source closure. A
statically known non-exact Function edge may conditionally wrap it with a
target tag/native adapter and consumer-local relay. If realization is
ineligible—or a later dynamic view has another tag—the final strict
light-C-function entry applies the frozen gradual actions and reaches the bound
native route. Generic stack representation alone does not select the coercive
Lua rules.

### Bound method values

An Interface bound-method **source** closure has six zero-based upvalues:

```text
0  Interface-owner module Udata
1  self-removed function-type tag
2  native bound trampoline pointer
3  TITAN_BRAND
4  captured Interface wrapper
5  strict Lua-stack entry
```

Its `CClosure.f` is the coercive Lua trampoline. Exact source calls use
upvalue 2; branded source-tag mismatches use upvalue 5; genuine Lua calls use
`CClosure.f`. A realized adjustment copies the captured Interface wrapper,
appends the bound source closure as its immediate-source link, replaces
upvalue 1/2 with target tag/adapter, and stores the target relay last. The
native trampoline loads the copied method slot and hidden concrete values from
the captured wrapper. The Lua trampoline inserts that
same wrapper as receiver and delegates to the Interface method's Lua entry.

The Interface owner exports the native bound trampoline, Lua trampoline, and
strict entry for each method. This lets a bind site in another DSO or archive
construct the same branded closure without importing an implementer.

## Metatable identity and dynamic boundaries

Each Interface owner initializes one protected metatable per Lua state under:

```text
Titan interface <fully-qualified-name> metatable
```

It contains a read-only `__index` member map, a rejecting `__newindex`, and the
protected display string `Titan interface <fully-qualified-name>`. Field names
select snapshot user values; method names select their generic closures. The owner
caches the metatable in a private module user value. Importing modules allocate
their own private cache slot and recover the exact registry metatable during
initialization. Interfaces consume no importer-reconstructed public-prefix
slot.

The central nominal leaf for an Interface target first performs the ordinary
exact-wrapper metatable check. Otherwise it requires full userdata with a
metatable and raw-reads that candidate metatable using the target Interface
metatable TValue as key. A missing entry takes the existing nominal type-error
path. A present entry is pushed with the candidate userdata and invoked through
`luaD_callnoyield` for one result; the returned Udata is trusted as the
Interface value without a second metatable or result-shape check.

This exact-or-witnessed leaf is shared by written `value as I`, implicit
`value -> I` projection, genuine Lua sinks, typed Array/Map reads, strict
callable observations, exported module/record writes, Array writers, and
non-Titan callable results. `I?` accepts nil first and recurses for a present
value. It never calls the checker structural matcher: only an initialized
compiled wrapper site advertises a pair.

The non-raising `is` form uses the same exact check and raw lookup but does not
call the entry. Any non-nil value therefore counts as present. Discovery does
not verify that the candidate metatable belongs to a Titan record/union and
does not verify callability; forged debug/native entries are outside Titan's
safety contract and retain ordinary Lua call errors and effects.

The VM call keeps the candidate, looked-up entry, and result in traced stack
slots. It may grow the stack, so generated native code saves offsets and
restores `_base`, while Lua-stack entry code reacquires slots from the current
`CallInfo`. This is stack-address hygiene rather than an additional object-root
inventory: metatables are traced objects, modules are registry/upvalue rooted,
and a successful wrapper retains the concrete through user value 1.

## Tests and concrete downcasts

For a statically satisfying concrete value, `r is I` reuses the checked
ordered mapping but emits no pair array, adapter, or wrapper. It evaluates the
operand once and returns true. A failed structural pair is rejected by the
checker rather than becoming false at run time.

For `value is I` and the corresponding strict predicate, code generation uses
exact Interface metatable identity or non-nil raw witness presence. It neither
invokes nor validates the entry, and therefore remains allocation-free. This
run-time predicate cannot itself cause a pair to be inventoried.

The reverse written operation is independent of satisfaction. `i is R` and
`i as R` read user value 1 and compare the concrete Udata's metatable with the
exact visible record/union metatable. The test returns false on mismatch; the
cast raises. For an optional Interface source, nil fails the concrete test or
cast before inspecting a wrapper. User value 0 is not needed for identity, but
remains retained for later method dispatch.

Interface equality is ordinary Udata identity. The comparability relation
does not consult a directional Interface coercion, so a wrapper is not
comparable with its concrete value or another nominal Interface.

## Separate compilation and schema validation

`types.serialize` emits Interfaces only as direct `Module.type_members`.
The driver's closed validator requires:

- the Interface owner name to match its module and type-member key;
- public/non-local locality;
- canonical dense field and method list/name-map projections whose combined
  length is nonzero and whose names are disjoint;
- each field to be an owned `Type.Field` with canonical zero-based index,
  required boolean `isconst == true`, and a recursively valid value-facing
  type;
- each method to be a public `Type.Method` owned by that Interface;
- a dense fixed parameter/result list;
- dense, unique parameter-name metadata matching fixed arity; and
- recursively valid value-facing parameter, result, input-tail, and
  flexible-result types.

`Type.Interface`, `Type.Field`, and `Type.Method` descriptors are rejected in
arbitrary value-facing positions in recovered metadata. The value graph is
closed: error-recovery/no-value markers, nested modules, legacy wrappers,
nonportable C FFI descriptors, and unknown tags are rejected. Contextual C
primitives and recursively valid pointer, C-function, and owned descriptors
are admitted only after their strict hostile-input schema is validated. A
recovered Titan function
type must carry the reserved `vararg=false` sentinel; typed variadics
use `varargtype`, while C variadicity exists only on unexportable
`Type.CFunction`. An Option cannot contain another Option or `value`, matching
source canonicalization.
At the module boundary, `ModuleMember` wraps only functions and direct
record/union declarations; ordinary values, including function-valued
variables, use `ModuleVariable`. Every nominal reference is a qualified
`<module>.<type>` name, and recovered record field names remain disjoint from
their static and method namespaces.
The source checker prevents nonexportable C descriptors and local nominals
from being serialized in the first place; owner recovery applies the
corresponding nominal-visibility and portable-C checks to imported signatures.
The same decoder and validator serve DSO callable metadata and embedded
archive metadata.

Recovered Interfaces are registered before their signature graph is walked.
The loader then follows transitive nominal references through the existing
provider-aware owner recovery. Source, selected static providers, and dynamic
providers retain the existing direct/handle/global native-binding rules for
concrete method symbols.

Static-provider and library preflight inventories the three exported bound
method symbols from recovered Interface type members, in addition to ordinary
module and nominal symbols. Interface artifacts follow the current native hierarchy:
`<module>_\u2133_<owner>_\u2131_<member><role>`, matching record and
union callables. Pair arrays and adjustment entries are private to
the translation unit that needs a concrete/Interface conversion; its witness
function and per-state closure/metatable entry are private as well. None add
serialized metadata or public symbols. Because concrete and Interface owners
recover canonical metatables per state, a witness initialized from one DSO or
archive can be discovered by an unrelated consumer without a direct concrete
import. Older same-ABI objects remain valid but advertise no pair they were not
compiled to witness.

## ABI, GC, and failure boundaries

The compiled-module ABI covers:

- `Type.Interface` and ordered `Type.Method` metadata in
  `Module.type_members`;
- the two-user-value Interface wrapper and copied function-pointer payload;
- generated Interface metatable and dispatch artifacts;
- the concrete-owner module retention rule; and
- the exported bound native/Lua/strict trampoline set.

ABI 2 includes the two-user-value Array proxy, strict generic function entry,
ordered Interface field descriptors and const booleans, field adjustment
mappings, and one wrapper user value per field. The generalized callable
action graph, `nil_fill_result`, and
first-class closure wrappers still add no provider symbol. Target wrapper
adapters, field allocators, witnesses, and strict relays are consumer-private.
A mismatched provider is rejected before its metadata or wrapper layout is
used. There is no compatibility adapter or migration path.

The wrapper, concrete module, concrete value, and field snapshots use stock Lua
reachability. All `2 + field_count` user values are strong traced edges with
ordinary backward barriers; the opaque vtable is untraced native data. Every new Interface Udata receives
its own immediate root, and bound closures strongly retain the wrapper through
upvalue 4. Native adapters keep inputs in C, root newly allocated converted
objects individually, and root every live GC-bearing fixed/open native source
result immediately after return. Raw descriptors/C arrays and allocation-free
input/destination runs never become roots.

A witness closure strongly retains its emitting module; that module's traced
uservalues retain imported owners and cached metatables, while the Lua registry
owns every canonical nominal metatable. During a witness call the bare input is
an argument stack value, the new wrapper replaces that same traced slot, and
its user value 1 retains the input before return. Snapshot temporaries and the
destination wrapper remain traced across allocating adjustments; collectable
snapshot stores receive Udata barriers. The discovery protocol needs no
additional long-lived root beyond these existing edges.

All type mismatches raise through the ordinary Titan/Lua error path. Wrapper
allocation can fail before publication without leaving external native
ownership. Adapter failures abandon only traced stack temporaries and unwind
through the existing handler. Debug-library or C-API mutation of wrapper
payload, user values, or metatables is outside Titan's untrusted-code
contract.

## Focused evidence

The main regression suites are:

- `spec/parser_spec.lua` and `spec/lexer_spec.lua` for syntax and keyword
  boundaries;
- `spec/types_spec.lua` for descriptor, relation, matching, and plan laws;
- `spec/checker/interfaces_spec.lua` for staging, visibility, conversions,
  field/method matching, diagnostics, named methods, options, and casts;
- `spec/coder/interfaces_spec.lua` for wrapper layout, exact/adjusted
  dispatch, field snapshots, field-only wrappers, bound closures, Lua behavior,
  GC, traces, and four-module separation;
- `spec/union_interface_spec.lua` for hostile serialized schemas;
- the compiled-module and static-provider suites for DSO/archive recovery and
  symbol preflight; and
- `spec/libuv_build_spec.lua` for the seven ordered `titan.io` Interface
  descriptors.
