# Interfaces

Interfaces add one nominal, type-only declaration and one run-time wrapper
representation. A record or union does not acquire an Interface supertype.
Instead, the checker may authorize one direct concrete-to-Interface coercion
at a statically known use site, and the coder lowers it to a fresh wrapper
holding the emitting module, the concrete receiver, a declaration-order method
table, and declaration-order field snapshots. Code generation also advertises
every emitted concrete/Interface pair on the concrete metatable, so a later
dynamic observation can build the same wrapper after type erasure without a
new relation.

The language contract is in [Interfaces](../language/interfaces.md). This
chapter covers the parser, type descriptors, checker plans, generated
representation, dispatch paths, loader contract, and ABI.

## Frontend representation

`interface` is a Titan keyword, but contextual identifier positions in the C
FFI still accept the spelling as a C typedef, field, module member, or
prototype parameter.

`interfacedecl` (`parser.lua`) admits a top-level declaration whose body mixes
fields and bodyless methods. `defs.interfacedecl` and its member actions emit:

```lua
Ast.TopLevelInterface(loc, name, members, fields, methods, typeparams)
Ast.Decl(loc, name, type, false, true) -- Interface field
Ast.InterfaceMethod(loc, name, params, rettypes, flexrettype, typeparams)
```

`members` keeps source order, while `fields` and `methods` are the dense
per-kind projections used by checking. A field is `name: T`, represented as an
exact-const declaration; the record-only optional-name shorthand is not
accepted. An `InterfaceMethod` has no body; its parameters and results use the
ordinary fixed, named, typed-tail, and flexible-result nodes.

The parser reports `local interface` (`LocalInterface`) and malformed members
through the `NameInterface`, `MemberInterface`, `TypeInterfaceField`,
`NameInterfaceMethod`, `LParInterfaceMethod`, `RParInterfaceMethod`, and
`EndInterface` labels. It accepts an empty body; the checker rejects it.

The checked descriptors are:

```lua
Type.Interface(name, fields, methods, scope, typeparams)
Type.Field(fqtn, name, type, index, true)
Type.Method(fqtn, name, params, rettypes,
            varargtype, flexrettype, paramnames, scope, typeparams)
```

`name` and `fqtn` are the same fully qualified Interface identity.
`Interface.fields` and `Interface.methods` are independent hybrid lists: the
numeric entries keep declaration order within their kind, and `list[name]`
points to the same descriptor. `types.Interface` accepts only two dense numeric
lists whose combined length is nonzero, rejects duplicate and cross-kind names
and mismatched owners, requires canonical zero-based field indices and
`isconst == true`, and derives the name keys itself.
`types.validate_interface_descriptor` rechecks those projections.

Field and method order are ABI-significant. Serialization writes both numeric
lists in order and rebuilds the name maps through `types.Interface`; it never
sorts either kind by name.

## Declaration staging and publication

Interfaces share the type-only namespace with aliases, records, and unions.
`collect_type_aliases` (`checker/declarations.lua`) precollects Interface and
alias spellings (Interfaces into `st.interface_declarations`) before signature
checking. A record or union owns both the value and type spelling and wins a
conflict regardless of source order; among aliases and Interfaces the first
declaration wins.

Interfaces are checked after imports, aliases, and record/union descriptors
([staged top-level collection](checker.md#staged-top-level-collection-and-body-checking)),
so every nominal used in a member signature is available. The
`Ast.TopLevelInterface` handler of `toplevel_visitor`:

1. rejects an empty body ("interface '%s' must declare at least one field or
   method") and more than 65,533 fields;
2. reserves the shared member namespace in source order, rejecting duplicate
   ("redeclaration of %s '%s' in interface '%s'") and cross-kind ("member '%s'
   in interface '%s' is declared as both a %s and a %s") names;
3. builds each `Type.Field` in field order and each `Type.Method` in method
   order, recording fixed parameter names for named calls and rejecting
   duplicate parameter names;
4. checks every field and callable component with the ordinary type
   validator, rejecting nonexportable C descriptors and local nominal types;
   and
5. registers the descriptor under its fully qualified name in
   `types.registry`.

Interfaces have no value declaration, constructor, module accessor, or public
module-userdata slot. `checker.makemoduletype` (`checker/imports.lua`)
publishes them in `Type.Module.type_members`, next to type aliases.
`checker.register_module_interface` registers every direct Interface
descriptor of an imported module before traversing any signature, so mutually
referring Interfaces and transitive nominal owners are available while a
compiled module is recovered.

## Direct structural satisfaction

`types.interface_implementation(concrete, interface, policy)` is a dedicated
predicate, not a branch of gradual consistency or a subtyping relation. The
checker supplies the cast-site module and member-visibility callback in
`policy`; the relation layer neither resolves nominal descriptors nor decides
visibility.

It scans both ordered projections. Each field slot requires:

- a same-named `Type.Field` on the concrete owner, not a method or static;
- visibility from the conversion site;
- `isconst == true`; and
- an ordinary automatic assignment plan from the concrete field type to the
  Interface field type.

A union has no fields, so an Interface with fields always fails for a union;
the checker words that failure as "interface fields require a record
implementation; field '%s' cannot be supplied by a union"
(`checker/interfaces.lua`).

Each method slot requires:

- a same-named `Type.Method` on the concrete record or union, not a field,
  record/union function, or union variant;
- visibility from the conversion site; and
- directional callable adjustment from the concrete method's self-removed
  function type to the Interface method's self-removed function type.

`types.method_function_type` projects both methods to ordinary
`Type.Function` shapes; declaration-only parameter names take no part in
identity or adjustment. Aligned components may be exact, gradually consistent,
or nested callable adjustments, and a missing concrete result may use
[`nil_fill_result`](closure-adjustment-wrappers.md#relation-contract-nil_fill_result).
`component_adjustment` (`types.lua`) does not consult ordinary coercion, so
numeric, Option, C, and concrete-to-Interface coercions do not lift through a
method signature.

The result keeps independent ordered field and method mappings. A field
mapping freezes the source/target indices, descriptors, types, and assignment
plan. A method mapping keeps:

```text
slot, name, required Interface Method, concrete Method,
source function shape, target function shape, adjustment, exactness
```

A failure names the first failing field in field order or, after all fields
pass, the first failing method in method order. Its kind is `missing`,
`not_field`, `not_method` (wrong-kind collisions), `inaccessible`, `mutable`,
or `incompatible`.

The scalar coercion path sees only `Type.Nominal` endpoints. At an ordinary
target-typed use site, the checker passes a policy callback to
`types.coercion`; the callback resolves both descriptors and authorizes only
the direct outer `interface_wrapper` plan. Options use the outer `option_wrap`,
`option_force`, or `option_map` compositions around that scalar plan.

`types.consistent` has no concrete/Interface or Interface/Interface case, so
its Array, Map, Option, and Function recursion cannot turn satisfaction into a
compound relation, and distinct Interfaces stay unrelated. This is what keeps
an accepted `R -> I` coercion from implying `{R} -> {I}` or
`function (): (R)` to `function (): (I)`.

## Frozen conversion and adapter plans

The checker attaches `_interface_conversion` to every accepted wrapper
construction. It holds the exact concrete and Interface descriptors, their
nominal value types, the ordered field and method mappings, pair exactness,
and any outer Option operation. It is the coder's authority to allocate; the
coder never reruns structural matching.

Each field mapping freezes its ordinary assignment adjustment, which, unlike a
method component, may itself construct an Interface or callable wrapper.
Method mappings are frozen by `make_interface_adapter`
(`checker/interfaces.lua`), which also chooses the slot kind:

- an **exact** slot points directly at the concrete method's native entry. It
  is used only when the signatures are identical **and** the concrete owner's
  module is the cast-site module;
- every other slot, including an identical signature on a concrete type from
  another module, becomes an **adapter** slot with a frozen
  `interface_method_adapter` plan.

The adapter plan reuses the closed, relation-free callable action subgraph of
first-class closure adjustments ([one frozen callable-adapter
plan](closure-adjustment-wrappers.md#one-frozen-callable-adapter-plan)) and adds
Interface-specific hidden operands, root inventory, stack-rebase ledger,
lifetime labels, and a known-method invocation backend. Its operations are
limited to identity, gradual injection, a gradual guard whose timing is frozen
as an immediate projection or a representation-preserving delayed Array/Map
observation, a nested frozen callable adjustment, and the ordinary
argument/result run actions (fixed slots, missing-argument nil fill,
`nil_fill_result`, ignored slots, typed tails, flexible tails, hidden surplus
results). `freeze_callable_component` rejects a nested concrete-to-Interface
conversion in a method-component graph. The coder
(`coder._validate_interface_adapter`) rechecks the closed records, their dense
lists, and the action sequence against both method descriptors, and never
calls a type relation while emitting an adapter.

For a finite flexible-result request, the adapter consumes surplus fixed
concrete results before asking the concrete flexible tail for more, so
discarded tail values are never inspected by a gradual guard; `LUA_MULTRET`
forwards an open demand unchanged.

`coder._interface_pair` (`coder/interfaces.lua`) records one pair obligation
per concrete/Interface pair that a translation unit actually constructs, keyed
by `concrete .. "\0" .. interface`. `coder.generate` (`coder/generate.lua`)
drains `interface_pair_list` as a growing worklist, preparing each pair's
wrapper with `coder._prepare_interface_pair_wrapper`; a field snapshot may add
nested pairs, so the drain reaches a fixpoint before the list is sorted with
`util.bytewise_less` and emitted. The emitter never adds a pair to a frozen
inventory. Private pair and adapter symbols encode both names injectively
(hex fragments from `coder._interface_symbol_fragment`) plus the slot index.
Each pair also gets a private witness and, when it has fields, an allocator,
named in the emitting module's native hierarchy as
`coder._function_prefix(module, <concrete>)` followed by
`_\u2131_<interface>_\u2131_wrapper` or `_allocate`. Allocation-free static
`is` tests validate their frozen mapping without registering a pair, so only
real wrapper construction advertises a pair, and discovery order cannot change
generated identities.

## Wrapper representation

Every Interface value is a full `Udata` with:

- an opaque payload of `method_count * sizeof(TitanInterfaceMethod)` bytes;
- exactly `2 + field_count` traced user values;
- the canonical metatable of the fully qualified Interface; and
- no mutable state.

```text
payload[0 .. method_count-1]  copied native method entries
user value 0                  emitting module Udata (the cast site's _mod)
user value 1                  concrete record/union Udata
user value 2 + i              target-typed snapshot of Interface field i
metatable                     exact Interface identity
```

`TitanInterfaceMethod` is a function-pointer storage type in
`titan-runtime/titan.h`. Generated code converts entries to and from it with
`titan_cast_func` (`titan-runtime/titan/ffi.h`); the payload never contains
data pointers and is not a GC graph. A field-only wrapper has a zero-byte
payload, and no zero-length C array or `memcpy` is emitted for it.

**User value 0 is the emitting module.** It is the `_mod` of the translation
unit that emitted the pair, never the Interface owner, and it equals the
concrete owner only for a same-module concrete type. This is consistent
because slot kinds depend on it: an exact slot exists only when the concrete
owner is that module, and an adapter slot recovers the concrete owner with
`coder._interface_owner_module_expr` from the emitting module's private import
slots. The exact-slot rule relies on a checker precondition:
`checker/interfaces.lua` `make_interface_adapter` also chooses an exact slot
when no `cast_module` is given, but every cast site supplies `cast_module`
(`interface_relation_policy` sets it to the checking module).
`coder._interface_pair` asserts that an exact slot's concrete owner is the
emitting module when it validates the pair's slots.
For both slot kinds, dispatch passes user value 0 as `_mod` and the concrete
method receives its own module.

**Pair arrays.** The emitting module's per-state native payload holds one
`TitanInterfaceMethod` array per pair with at least one method. Fresh module
initialization fills each slot with the exact concrete entry or the private
adapter after imported native symbols are recovered and before a user
initializer can construct a wrapper. Each Lua state's array uses that state's
selected native providers. Every method-bearing wrapper copies the complete
array with `memcpy`; arrays and wrappers are not interned.

**Construction.** `coder._render_interface_wrapper_allocation` is the shared
body. `coder._code_interface_wrapper` evaluates the concrete value once into an
untraced C temporary, relying on its ordinary provenance. A method-only pair is
allocated inline; a field-bearing pair calls the pair's allocator. Either way
the body:

1. evaluates every field snapshot in Interface field order, applying its
   frozen adjustment, into traced temporaries (`coder._code_interface_field_snapshots`);
2. allocates with `luaS_newudata(L, payload_size, 2 + field_count)`, treating
   it as a stack-rebase point that restores `_base` from `_base_off`, and
   immediately publishes the new Udata to its root;
3. installs the Interface metatable from the emitting module's cache;
4. stores `_mod` in user value 0 and the concrete value in user value 1, each
   with `luaC_barrierback`;
5. stores each snapshot in user value `2 + i` with a barrier; and
6. copies the pair array into the payload when methods exist.

Nested Interface or callable construction inside a field adjustment can
allocate and move the stack, so sources and destinations are recovered from
saved offsets after each such operation; no stale `StkId` spans a possible
rebase. The checker limits fields to 65,533, which keeps `2 + field_count`
within Lua's uservalue bound.

**Witnesses.** Each pair also emits one private `lua_CFunction` witness
(`coder._prepare_interface_pair_wrapper`). It reads the emitting module from
its upvalue 0 and a bare concrete Udata from stack slot 1, builds the wrapper
with the same body, replaces slot 1 with the result, and returns one value; the
argument stays traced throughout, and only the witness body itself is limited
to direct stack manipulation. During the same initialization step that fills
the pair arrays, generated code raw-reads the concrete metatable at the target
Interface metatable key. If the entry is empty, it stores a one-upvalue C
closure of the witness capturing `_mod`; a non-empty entry is left alone, so
the first registered witness in a state wins.

## Native entry ABI and adjustment entries

A concrete method uses the ordinary method ABI:

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

An exact slot points at that entry. An adapter slot points at a private
function (`coder._emit_interface_adapter`) with the Interface method's native
signature and the hidden operands `_mod` = user value 0 (the emitting module),
`_fn` = `NULL`, and `_self` = user value 1. The adapter converts Interface
arguments to the concrete shape, calls the concrete method with
`coder._interface_owner_module_expr(...)`, `NULL`, and `_self`, and converts the
results back. A `nil_fill_result` initializes the first C return or the later
out-parameter without reading a concrete result. Because `_mod` is the emitting
module, every Array, nominal, and owned-C identity an immediate guard needs is
read from `_mod->uv[slot]` without a registry lookup.

Adapters share the closure adapter's action, root, and rebase engine; only
the known-method invocation differs. The rules for open runs, rooting, and
stack rebases are in [Roots, relocation, and
errors](closure-adjustment-wrappers.md#roots-relocation-and-errors). In short:
inputs stay in C with no input roots, fresh nested wrappers get immediate
roots, and every live GC-bearing concrete result is rooted immediately after
the native call. When the action graph can allocate a nested callable view,
the adapter polls the collector with `luaC_checkGC` at entry, before reserving
stack space or establishing `_base`.

## Four dispatch paths

Field access does not use the method payload. A native read
(`coder/expressions.lua`) loads user value `2 + target_index` and unboxes it
under the target type; it relies on the static layout and performs no run-time
user-value count check. Lua `__index` distinguishes a field from a method name
and boxes the same snapshot slot. Both paths read the conversion-time value,
and every assignment path classifies an Interface field as const and rejects
the write.

### Direct Titan method calls

For `wrapper:method(...)` (`coder/calls.lua`), generated code freezes the
wrapper once into an untraced C temporary before later argument effects and
creates no input root. It checks that the payload length is exactly the
Interface's method count ("malformed internal Interface wrapper for %s"),
loads the declaration-order slot, rejects a `NULL` entry ("uninitialized
internal Interface method %s:%s"), casts it to the method signature, and calls
it with:

```text
wrapper.user_value_0, NULL, wrapper.user_value_1, arguments...
```

The common path is one indexed payload load plus an ordinary native call.

### Genuine Lua method calls

The Interface owner generates a Lua entry for every method
(`coder/declarations.lua`). Its metatable method map stores one closure per
public method, capturing the Interface owner's module so argument and result
conversion uses the Interface signature's identities. The entry converts
argument 1 through the exact-or-witnessed Interface leaf (below), applies the
ordinary Lua-boundary dynamic plans to the declared arguments, performs the same
payload checks as a direct call, and invokes the slot with user values 0 and 1.
Results are boxed for Lua. A bare record or union reaches the payload only
after a registered witness has built its wrapper.

### Strict Titan generic calls

A bound Interface method starts as an ordinary branded Titan source closure. A
statically known non-exact Function edge may wrap it with a target tag, native
adapter, and consumer-local relay ([closure adjustment
wrappers](closure-adjustment-wrappers.md)). If realization is ineligible, or a
later dynamic view has another tag, the strict light-C-function entry applies
the frozen gradual actions and reaches the bound native route. The generic
stack representation alone does not select the coercive Lua rules.

### Bound method values

`codemethodref` (`coder/declarations.lua`) builds Interface bound methods with
the general six-upvalue layout of [bound-method
trampolines](codegen-overview.md#bound-method-trampolines). For an Interface,
upvalue 0 is the Interface owner's module, upvalue 4 is the captured wrapper,
and the native, Lua, and strict trampolines are the Interface owner's
`coder._interface_bound_method_name`, `_luaname`, and `_strictname` symbols.
The native trampoline loads the method slot and the hidden concrete values
from the captured wrapper; the Lua trampoline inserts the wrapper as receiver
and delegates to the Interface method's Lua entry. A realized adjustment copies
the captured wrapper, appends the bound source closure as its immediate-source
link, replaces upvalues 1 and 2 with the target tag and adapter, and stores the
target relay last. Because the Interface owner exports all three trampolines,
a bind site in another DSO or archive can build the closure without importing
an implementer.

## Metatable identity and dynamic boundaries

`coder._codeinterfacedec` (`coder/module.lua`) initializes one protected
metatable per Lua state under the registry key
`Titan interface <fully-qualified-name> metatable`. It has a read-only
`__index` member map (field names select snapshot user values, method names
select their Lua closures), a `__newindex` that always raises, and the
protected `__metatable` string `Titan interface <fully-qualified-name>`. The
owner caches the metatable in a private module user value; importing modules
allocate their own cache slot and recover the registry metatable during
initialization. The reflection metadata keys it also publishes are listed in
[Discoverable runtime type
information](lua-interop-internals.md#discoverable-runtime-type-information).

The nominal leaf for an Interface target (`checkandget`, `coder/values.lua`)
first checks the exact wrapper metatable. Otherwise it requires full userdata
with a metatable and raw-reads that metatable (`luaH_get`) with the target
Interface metatable as key. An empty entry takes the ordinary nominal
type-error path. A present entry is pushed with the candidate and called with
`luaD_callnoyield` for one result, and the returned Udata is trusted as the
Interface value without another metatable or shape check.

That exact-or-witnessed leaf serves written `value as I`, implicit
`value -> I` projection, genuine Lua sinks, typed Array/Map reads, strict
callable observations, exported module and record writes, Array writers, and
non-Titan callable results. `I?` accepts nil first and recurses for a present
value. It never runs the checker's structural matcher: only an initialized
compiled wrapper site advertises a pair.

The non-raising `is` form (`coder._code_interface_discovery_predicate`,
`coder/numerics.lua`) uses the same exact check and raw lookup but does not
call the entry, so any non-empty entry counts as present. Discovery does not
check that the candidate metatable belongs to a Titan record or union or that
the entry is callable. Forged entries installed through debug or native code
are outside Titan's safety contract and keep ordinary Lua call errors and
effects.

The witness call keeps the candidate, entry, and result in traced stack
slots. It may grow the stack, so generated native code saves offsets and
restores `_base`, while Lua-stack entry code reacquires slots from the current
`CallInfo`. This is stack-address hygiene, not an extra root inventory.

## Tests and concrete downcasts

For a statically satisfying concrete value, `r is I` reuses the checked
mapping but emits no pair array, adapter, or wrapper; it evaluates the operand
once and yields true. A failing pair is a checker error, never a run-time
false.

For `value is I` and the matching strict predicate, code generation uses exact
Interface metatable identity or witness presence without invoking or
validating the entry, so it allocates nothing and never inventories a pair.

The reverse operations are independent of satisfaction.
`coder._code_interface_downcast` implements `i is R` and `i as R` by reading
user value 1 and comparing the concrete Udata's metatable with the exact
visible record or union metatable. The test yields false on mismatch and the
cast raises. For an optional Interface source, nil fails the test or cast
before any wrapper is inspected.

Interface equality is ordinary Udata identity. Comparability does not consult
the directional Interface coercion, so a wrapper is not comparable with its
concrete value or with another Interface.

## Separate compilation and schema validation

`types.serialize` emits Interfaces only as direct `Module.type_members`.
`validate_declared_interface` (`driver.lua`) requires:

- the Interface owner name to match its module and type-member key;
- public (non-local) locality;
- canonical dense field and method lists and name maps whose combined length
  is nonzero and whose names are disjoint;
- each field to be an owned `Type.Field` with a canonical zero-based index,
  `isconst == true`, and a recursively valid value-facing type; and
- each method to be a public `Type.Method` owned by that Interface, with dense
  fixed parameter and result lists, dense unique parameter names matching the
  fixed arity, and recursively valid parameter, result, input-tail, and
  flexible-result types.

The recovered value graph is a closed descriptor language shared by DSO
callable metadata and embedded archive metadata. `Type.Interface`,
`Type.Field`, `Type.Method`, `StaticMethod`, `ModuleMember`, and `Variant`
descriptors are rejected in value-facing positions ("Type.Interface is only
valid as its owning module type member"). Error-recovery and no-value markers,
nested modules, legacy wrappers, nonportable C descriptors, and unknown tags
are rejected. Contextual C primitives and pointer, C-function, and owned
descriptors are admitted only after their strict schema is validated. A Titan
function type must carry the reserved `vararg = false` sentinel; typed
variadics use `varargtype`, and C variadicity exists only on the
nonexportable `Type.CFunction`. An Option cannot contain another Option or
`value`. `ModuleMember` wraps only functions and direct record/union
declarations; ordinary values, including function-valued variables, use
`ModuleVariable`. Every nominal reference is a qualified `<module>.<type>`
name, every recovered member is nonlocal, and record field names stay disjoint
from their static and method namespaces. The source checker keeps
nonexportable C descriptors and local nominals out of serialized metadata in
the first place.

Recovered Interfaces are registered before their signature graph is walked,
and the loader follows transitive nominal references through the
provider-aware owner recovery. Source, static, and dynamic providers keep
their direct, handle, and global native-binding rules for concrete method
symbols.

`coder.interface_external_symbols` (`coder/names.lua`) inventories, for static
provider and library preflight, the three exported bound-method symbols of
each recovered Interface method in addition to ordinary module and nominal
symbols. They follow the native hierarchy
`<module>_\u2133_<owner>_\u2131_<member><role>` used by record and union
callables. Pair arrays, adapters, allocators, witnesses, and the per-state
witness entry are private to the translation unit that needs the conversion
and add no serialized metadata or public symbols. Because concrete and
Interface owners recover canonical metatables per state, a witness registered
by one DSO or archive can be discovered by an unrelated consumer that does not
import the concrete type.

## ABI, GC, and failure boundaries

The compiled-module ABI covers:

- `Type.Interface`, ordered `Type.Field` descriptors with const booleans, and
  ordered `Type.Method` metadata in `Module.type_members`;
- the `2 + field_count` user-value wrapper and copied function-pointer
  payload;
- the generated Interface metatable and dispatch artifacts;
- the user-value 0 module rule; and
- the exported bound native, Lua, and strict trampolines.

Adapters, allocators, witnesses, and strict relays are consumer-private and
add no provider symbol. A mismatched provider is rejected before its metadata
or wrapper layout is used.

The wrapper, its module, the concrete value, and the field snapshots use
ordinary Lua reachability. All `2 + field_count` user values are strong traced
edges with backward barriers; the method payload is untraced native data.
Every new wrapper gets its own immediate root, and bound closures retain the
wrapper through upvalue 4. A witness closure retains its emitting module, whose
user values retain imported owners and cached metatables, while the registry
owns every canonical metatable. During a witness call the bare input is an
argument stack value, the new wrapper replaces that same traced slot, and user
value 1 retains the input before return. Witness discovery needs no other
long-lived root.

Type mismatches raise through the ordinary Titan/Lua error path. Wrapper
allocation can fail before publication without leaving external native
ownership, and adapter failures abandon only traced stack temporaries and
unwind through the existing handler. Debug-library or C-API mutation of a
wrapper's payload, user values, or metatable is outside Titan's
untrusted-code contract.

## Focused evidence

The main regression suites are:

- `spec/parser_spec.lua` and `spec/lexer_spec.lua` for syntax and keyword
  boundaries;
- `spec/types_spec.lua` for descriptor, relation, matching, and plan laws;
- `spec/checker/interfaces_spec.lua` for staging, visibility, conversions,
  field/method matching, diagnostics, named methods, Options, and casts;
- `spec/coder/interfaces_spec.lua` for wrapper layout, exact and adjusted
  dispatch, field snapshots, field-only wrappers, bound closures, Lua
  behavior, GC, traces, and multi-module separation;
- `spec/union_interface_spec.lua` for hostile serialized schemas;
- the compiled-module and static-provider suites for DSO/archive recovery and
  symbol preflight; and
- `spec/libuv_build_spec.lua` for the seven ordered `titan.io` Interface
  declarations.
