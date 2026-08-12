# Interfaces

Interfaces add one nominal, type-only declaration and one run-time wrapper
representation. A record or union does not acquire an Interface supertype.
Instead, the checker may authorize one direct concrete-to-Interface coercion
at a statically known use site, and the coder lowers that coercion to a fresh
wrapper containing the concrete receiver, its owning module, and an ordered
method table.

The language-visible contract is in
[Interfaces](../language/interfaces.md). This chapter describes the parser,
type descriptors, checker plans, generated representation, dispatch paths,
loader contract, and ABI.

## Frontend representation

`interface` is a Titan keyword, but the C FFI's contextual identifier
positions still accept the spelling as a C typedef, field, module member, or
prototype parameter.

The parser admits only a top-level, non-local, nonempty declaration. It emits:

```lua
Ast.TopLevelInterface(loc, name, methods)
Ast.InterfaceMethod(loc, name, params, rettypes, flexrettype)
```

An `InterfaceMethod` has no body. Its parameter list uses the ordinary
fixed/named and optional typed-tail representation; its result list likewise
uses the existing fixed and flexible-result nodes. Parser-specific diagnostics
cover local or nested declarations, an empty body, local methods, missing
names/parentheses/types, unexpected members, and a missing final `end`.

The checked descriptors are:

```lua
Type.Interface(name, methods)
Type.Method(fqtn, name, params, rettypes,
            varargtype, flexrettype, paramnames)
```

`name` and `fqtn` are the same fully qualified Interface identity.
`Interface.methods` is a hybrid ordered list and name map: numeric entries
retain declaration order, while `methods[name]` points to the same descriptor.
The public constructor accepts only a nonempty dense numeric list, rejects
duplicate names and mismatched owners, and derives the string keys itself.
`types.validate_interface_descriptor` rechecks that canonical projection
after construction.

Declaration order is ABI-significant. Serialization writes the numeric method
list in order and reconstructs the name map through `types.Interface`; it
does not sort methods by name.

## Declaration staging and publication

Interfaces share the type-only namespace with aliases, records, and unions.
The checker precollects Interface and alias spellings before signature
checking. A record or union owns both the value and type spelling and wins a
conflict regardless of source order; Interfaces and aliases otherwise retain
the existing first-declaration-wins policy.

The signature pass runs imports and aliases first, then record/union
descriptors, then Interfaces. This makes every nominal used in a method
signature available without changing the AST's source order. Checking an
Interface:

1. builds each `Type.Method` in declaration order;
2. records fixed parameter names for named calls;
3. rejects duplicate method and parameter names;
4. checks every fixed/tail component with the ordinary type validator;
5. rejects exported C FFI types and local nominal types; and
6. registers the completed descriptor under its fully qualified name in
   `types.registry`.

Interfaces have no value declaration, constructor, module accessor, or public
module-userdata slot. `checker.makemoduletype` publishes them directly in
`Type.Module.type_members`, alongside type aliases. Imported module
registration installs all direct Interface descriptors before traversing
their signatures, so mutually referring Interfaces and transitive nominal
owners are available while recovering a compiled module.

## Direct structural satisfaction

`types.interface_implementation(concrete, interface, policy)` is a dedicated
predicate, not a branch of gradual consistency or a subtyping relation. The
checker supplies the cast-site module and method-visibility callback in
`policy`; the generic relation layer does not resolve nominal descriptors or
decide visibility.

The predicate scans the Interface's numeric method list. For each slot it
requires:

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

The result retains one ordered mapping per Interface slot:

```text
slot, name, required Interface Method, concrete Method,
source function shape, target function shape, adjustment, exactness
```

A failure identifies the first declaration-order slot and classifies the
problem as missing, non-method collision, inaccessible, or incompatible.

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
descriptors, their nominal value types, the ordered mappings, pair exactness,
and any outer Option operation. It is the coder's authority to allocate; the
coder does not rerun structural matching.

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
this graph. The Interface adapter records a minimal fixed/open root inventory:
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

For a finite flexible-result request, the adapter first consumes any surplus
fixed concrete results before asking the concrete flexible tail for more.
Discarded concrete tail values therefore remain unevaluated by the gradual
guard; `LUA_MULTRET` still forwards an open demand unchanged.

Concrete/Interface pair obligations are collected on demand only in a
translation unit that constructs the wrapper. Their key is the fully qualified
concrete name followed by the fully qualified Interface name. The list is
sorted bytewise before emission, and private adapter symbols encode both names
injectively plus the declaration-order slot. Allocation-free `is` tests
validate their frozen mapping without registering a pair, so discovery order
does not affect generated identities.

## Wrapper representation

Every Interface value is a full `Udata` with:

- opaque payload length
  `method_count * sizeof(TitanInterfaceMethod)`;
- exactly two traced user values;
- the canonical metatable for the fully qualified Interface; and
- no public fields or mutable state.

The layout is:

```text
payload[0 .. method_count-1]  copied native method entries
user value 0                  concrete type's owning module Udata
user value 1                  concrete record/union Udata
metatable                     exact Interface identity
```

`TitanInterfaceMethod` is a function-pointer storage type declared in
`titan-runtime/titan.h`. Generated code converts concrete or adapter entries
to and from that storage through `titan_cast_func`; the payload never contains
data pointers and is not a GC graph.

One process-static pair array is emitted per used concrete/Interface pair.
After imported native symbols have been recovered, initialization fills each
slot with either the exact concrete method or the private adjustment entry.
This happens on both module-initialization branches and before a user module
initializer can construct a wrapper. Each wrapper copies the complete array
with `memcpy`; pair arrays and wrappers are not interned.

Wrapper construction evaluates the concrete value exactly once into an untraced
C temporary, relying on its ordinary allocation/result/semantic/VM provenance.
It resolves the concrete-owner module, obtains the Interface metatable from the
emitting module's cache, and allocates the full userdata with `luaS_newudata`.
This path conservatively treats that allocation as a stack-rebase point: it
saves `_base_off`, restores `_base` immediately after the call, and publishes
the new Udata to its own initial root before any later allocation or traced-edge
publication. Lua's collector does not move heap objects, while saved offsets
keep the destination root address valid if the stack array moves. It then:

1. installs the Interface metatable;
2. stores the concrete module in user value 0 and applies the Udata barrier;
3. stores the concrete value in user value 1 and applies the Udata barrier;
4. copies the ordered pair array into the opaque payload.

The concrete module is `_mod` when the concrete type belongs to the current
module. Otherwise the translation unit retains or recovers the concrete
owner's module Udata in a private module slot. It never substitutes the
Interface owner or emitting module.

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

The adapter reserves a separate transient identity-setup range—one slot for
ordinary registry lookup, or three when Array metatable creation must remain
possible—but advances `L->top` only across the actually rooted range. It records
`_base` as an offset, addresses rooted slots through `restorestack` across
identity setup, rebases after each immediate guard allowed to move the stack,
and always rebases after the concrete native call before reading result homes.
Direct nested `luaF_newCclosure` construction may allocate/raise but is not a
rebase point. A compile-time assertion keeps the adapter's 200-element backing
bound aligned with the runtime constant.

Adapters resolve any Array, nominal, or owned-C identities needed by immediate
guards at entry. This is necessary because an adapter may be emitted outside
both nominal owners while its `_mod` still deliberately names only the
concrete owner.

## Four dispatch paths

### Direct Titan method calls

For `wrapper:method(...)`, generated code evaluates the wrapper once into an
untraced C temporary before later argument effects. It creates no native input
root. It checks that
the payload contains exactly the Interface's method count, loads the
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

The entry dynamically checks argument 1 as the exact Interface receiver,
applies the ordinary Lua-boundary dynamic plans to the declared arguments,
loads the wrapper slot, then invokes the selected payload with the concrete
module and concrete self. Returning through the entry boxes results for Lua.
A bare record or union never reaches the payload because it fails the exact
Interface metatable check first.

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
3  TITAN_FUNCTION_CLOSURE_BRAND
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

It contains a read-only `__index` method map, a rejecting `__newindex`, and the
protected display string `Titan interface <fully-qualified-name>`. The owner
caches the metatable in a private module user value. Importing modules allocate
their own private cache slot and recover the exact registry metatable during
initialization. Interfaces consume no importer-reconstructed public-prefix
slot.

The central dynamic plan for an Interface target is the ordinary exact nominal
metatable check. It is shared by written `value as/is I` and genuine Lua sinks:
function arguments, exported module and record writes, non-nil Array writes,
and results returned by a non-Titan callable. It accepts only an existing
wrapper of that exact Interface. It never calls the structural matcher and
never constructs a wrapper after the concrete static type has been erased.
An `I?` plan accepts nil first and applies the same exact check to a present
value.

Typed Array/Map reads and strict callable observations remain gradual guards,
not Lua-boundary coercions. Raw Lua Map mutation is not intercepted; the later
typed read must observe an exact wrapper.

## Tests and concrete downcasts

For a statically satisfying concrete value, `r is I` reuses the checked
ordered mapping but emits no pair array, adapter, or wrapper. It evaluates the
operand once and returns true. A failed structural pair is rejected by the
checker rather than becoming false at run time.

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
- the canonical nonempty list/name-map projection;
- each entry to be a public `Type.Method` owned by that Interface;
- a dense fixed parameter/result list;
- dense, unique parameter-name metadata matching fixed arity; and
- recursively valid value-facing parameter, result, input-tail, and
  flexible-result types.

`Type.Interface` and `Type.Method` wrappers are rejected in arbitrary
value-facing positions in recovered metadata. The value graph is closed:
error-recovery/no-value markers, nested modules, C FFI descriptors, legacy
wrappers, and unknown tags are rejected as well. A recovered Titan function
type must carry the ABI-0.23 reserved `vararg=false` sentinel; typed variadics
use `varargtype`, while C variadicity exists only on unexportable
`Type.CFunction`. An Option cannot contain another Option or `value`, matching
source canonicalization.
At the module boundary, `ModuleMember` wraps only functions and direct
record/union declarations; ordinary values, including function-valued
variables, use `ModuleVariable`. Every nominal reference is a qualified
`<module>.<type>` name, and recovered record field names remain disjoint from
their static and method namespaces.
The source checker prevents C FFI types and local nominals from being
serialized in the first place; owner recovery applies the corresponding
nominal-visibility check to imported signatures. The same decoder and
validator serve DSO callable metadata and embedded archive metadata.

Recovered Interfaces are registered before their signature graph is walked.
The loader then follows transitive nominal references through the existing
provider-aware owner recovery. Source, selected static providers, and dynamic
providers retain the existing direct/handle/global native-binding rules for
concrete method symbols.

Static-provider and library preflight inventories the three exported bound
method symbols from recovered Interface type members, in addition to ordinary
module and nominal symbols. Interface artifacts follow the same ABI-0.23
`<module>_\u2133_<owner>_\u2131_<member><role>` hierarchy as record and
union callables. Pair arrays and adjustment entries are private to
the translation unit that needs a concrete/Interface conversion and do not
add serialized metadata or public symbols.

## ABI, GC, and failure boundaries

Interfaces entered the compiled-module contract in ABI 0.20. That boundary
covers:

- `Type.Interface` and ordered `Type.Method` metadata in
  `Module.type_members`;
- the two-user-value Interface wrapper and copied function-pointer payload;
- generated Interface metatable and dispatch artifacts;
- the concrete-owner module retention rule; and
- the exported bound native/Lua/strict trampoline set.

ABI 0.20 also introduced the two-user-value Array proxy and strict generic
function entry. ABI 0.21 retained those layouts while advancing the matched
Lua runtime to 5.5.1. ABI 0.22 retains those layouts; ABI 0.23 also retains
them while renaming the native bound and metatable entry families. The
generalized callable
action graph, `nil_fill_result`, and first-class closure wrappers add no
Interface schema/payload slot or provider symbol. Target wrapper adapters and
strict relays are consumer-private and use existing signatures, so there is no
new ABI bump. A 0.21 provider is rejected before its metadata is decoded or any
native value crosses the boundary; there is no compatibility adapter, migration,
or cleanup path, and separately versioned 0.20 and 0.21 artifacts remain
preserved.

The wrapper, concrete module, and concrete value use stock Lua reachability.
The two user values are strong traced edges with ordinary backward barriers;
the opaque vtable is untraced native data. Every new Interface Udata receives
its own immediate root, and bound closures strongly retain the wrapper through
upvalue 4. Native adapters keep inputs in C, root newly allocated converted
objects individually, and root every live GC-bearing fixed/open native source
result immediately after return. Raw descriptors/C arrays and allocation-free
input/destination runs never become roots.

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
  diagnostics, named methods, options, and casts;
- `spec/coder/interfaces_spec.lua` for wrapper layout, exact/adjusted
  dispatch, bound closures, Lua behavior, GC, traces, and four-module
  separation;
- `spec/union_interface_spec.lua` for hostile serialized schemas;
- the compiled-module and static-provider suites for DSO/archive recovery and
  symbol preflight; and
- `spec/libuv_build_spec.lua` for the seven ordered `titan.io` Interface
  descriptors.
