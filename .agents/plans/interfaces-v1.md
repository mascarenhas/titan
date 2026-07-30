# Interfaces v1 — expanded specification and implementation plan

Status: **maintainer decisions recorded and the separate type-relation
remediation implemented, review-complete, locally validated, and committed on
its companion branch, pending publication and exact-head Linux CI; do not
implement Interfaces yet. Interfaces and the prerequisite
relation/Array/function-layout repair share one ABI-0.20 cutover even if
reviewed as two PRs**.

Primary feature brief:
`/home/mascarenhas/.codex/attachments/54844c65-02b6-4be6-a695-e2d542790a5c/pasted-text-1.txt`

This plan expands the brief against the current compiler, runtime, manuals,
compiled-module format, standard-library bundle, installer, and CI layout. It
deliberately keeps interfaces nominal and small. Structural satisfaction is a
cast-site predicate used to construct one direct concrete-to-Interface
coercion plan. It is not subtyping, gradual consistency, or a relation closed
under structural contexts; there is no inheritance, interface embedding,
dynamic method discovery, or general object model.

The word *interface* is already used throughout the repository for serialized
compiled-module metadata. This plan uses **language interface** when that
distinction matters and **module interface** for the existing serialized
`Type.Module` graph.

## 0. Maintainer decisions recorded

The maintainer resolved the questions raised by the first plan review. These
are now requirements, not open recommendations. The requested relation audit
is recorded in `.agents/plans/type-relations-soundness.md`; Interface
implementation waits for acceptance and completion of that central
remediation, plus final approval of this revised plan.

That prerequisite now includes the two-uservalue Array proxy repair described
there: Titan Array reads use strict gradual guards, genuine-Lua Array writes
use the construction-time writer carried by the shared proxy, and neither
behavior creates a subtype or structurally lifted Interface conversion.
Every typed Titan Map read is likewise strict regardless of whether Titan or
raw Lua wrote the slot. Written `value as/is T` and genuine Lua-to-Titan
boundaries instead share the repaired central `DynamicCoercionPlan`; for an
Interface target its one admissible non-nil dynamic value is an existing exact
wrapper, never a bare implementer.

The relation/Array/function-layout and Interface changes may be separate
stacked or coordinated PRs, but the intermediate head is not a published ABI
boundary: ABI-0.20 release/provider compatibility begins only once both
layouts are present. The relation branch therefore proves its own 0.19
rejection and 0.20 internal consistency, while Interface-specific release
evidence remains a final gate of this plan.

### 0.1 Correct `read_until` to `chop: boolean?`

The brief writes:

```titan
function read_until(delimiter: string, chop?: string): string?
```

That is inconsistent in two ways:

- Titan parameters use `name: type`; `chop?:` is not current syntax.
- `net.Connection:read_until` and the existing OS process readers use
  `chop: boolean?`, not `string?`.

**Decision:** the brief contained a copy/paste error. All seven `titan.io`
interfaces use:

```titan
function read_until(delimiter: string, chop: boolean?): string?
```

Do not introduce suffix-optional parameter syntax as a side effect of
interfaces. Omitted arguments already nil-fill `boolean?`.

### 0.2 `_mod` always owns the concrete record/union

**Decision:** wrapper uservalue 0 is always the module object that owns the
wrapped concrete record/union type. Every exact method entry and every
adjustment wrapper receives that same concrete-owner `_mod`, followed by the
wrapped concrete `self`.

The translation unit that emits an adjustment wrapper is irrelevant to this
runtime contract. The wrapper calls the concrete method exactly as an ordinary
direct call would, using the concrete-owner `_mod`; it must never substitute
the caller module, casting module, or Interface owner. No third uservalue,
adapter closure/context object, registry identity workaround, or per-state
static module pointer belongs in the representation.

Tests still prove the contract for exact and adjusted methods originating in
the same module, an imported source module, a DSO, and an archive, and in two
independent Lua states. Their purpose is to catch a wrong-owner implementation,
not to reopen the two-uservalue design.

### 0.3 Model `R/U -> I` as one direct coercion, not compatibility or subtyping

**Decision:** do not add a record/union-to-Interface edge to the gradual
consistency relation and do not introduce an `R <: I`/`implements` subtype
relation. After the prerequisite relation repair, use:

```lua
types.coercion(source_nominal, target_nominal, {
    interface_coercion = cast_site_interface_matcher,
    visibility = cast_site_visibility,
})
    --> InterfaceWrapPlan | false
```

Ordinary value expressions carry `Type.Nominal` for both a concrete
record/union and an Interface. The policy callback therefore owns descriptor
resolution: it resolves the source nominal, proves that its owner descriptor
is a record or union, resolves the target nominal, proves that its owner
descriptor is an Interface, applies cast-site visibility, and returns the
method-adjustment payload. `types.coercion` authorizes no nominal pair without
that successful callback and records the original nominal source and target
in the resulting plan. Do not key this hook on expression types tagged
`Type.Record`, `Type.Union`, or `Type.Interface`; those are declaration
descriptors and would make the ordinary cast path dead.

The plan-producing relation invokes this private structural-satisfaction check
for the exact outer nominal pair. A successful result means only that this
concrete value can be used at this Interface-typed scalar sink after the
checker inserts the wrapper conversion. The prerequisite repair has removed
the old boolean `types.coerceable` API; Interface work extends the
plan-producing `types.coercion` relation directly.

Consequences:

- `assignment_adjustment` and the checker's `trycoerce` path must turn every
  admitted direct `R/U -> I` scalar use into an annotated `Ast.ExpCast` that
  constructs the wrapper;
- Option and expression-list adjustment reuse the existing coercion
  plans only through explicitly named scalar/Option/open-element actions,
  preserving nil/fixed/open-run behavior without a generic compound rule;
- repaired `types.consistent` is not taught that `R` and `I` have the same
  representation;
- Array/Map pointwise consistency does not lift the Interface coercion, so
  `{R}` is not consistent with `{I}` and the corresponding Map views are
  likewise rejected;
- ordinary Function consistency/callable assignment does not lift the
  Interface coercion, so `() -> R` is not usable as `() -> I`;
- the Interface method matcher uses the repaired directional
  `callable_adjustment(concrete_method, interface_method)` with ordinary
  coercions disabled in aligned component slots; adjustment wrappers may
  perform only the resulting shape actions and gradual guards, not nested
  `R/U -> I` conversions; and
- every ordinary coercion sink, including Map keys, follows the central
  assignment/coercion-plan policy. Because wrappers are fresh identities,
  documentation and tests must make the observable Map-key consequence
  explicit rather than inventing an Interface-only exception.

The maintainer separately requested an audit of the former `compatible`,
`coerceable`, and `explicitly_coerceable` APIs and all their callers. The
completed audit, constructed counterexamples, replacement relations, and
removal of those APIs are in
`.agents/plans/type-relations-soundness.md`. Interface implementation consumes
those repaired central relations; it must not grow private relation variants
or per-sink exceptions.

### 0.4 Use methods visible at the cast site

Source descriptors contain local methods; serialized record/union descriptors
omit them. Two coherent policies are possible.

**Decision:** structural satisfaction for the direct coercion uses the
concrete descriptor visible at the cast site.

- A local record/union may escape opaquely as a public interface.
- A public record/union's local method may satisfy an interface inside its
  owner module.
- An imported concrete type cannot satisfy an interface using a method that
  was not exported in its recovered descriptor.
- Once built, the copied vtable and its module/self roots are sufficient;
  consumers need neither the concrete descriptor nor the local method name.

This is visibility-sensitive by design. Requiring public methods everywhere
would be simpler to state but would make local records effectively unable to
implement interfaces, because their methods inherit owner locality.

Do not infer visibility merely from which descriptor object happens to be in
the process-global `types.registry`: a source import can share a full
descriptor that still contains local members, while serialized metadata is
already projected. The implementation matcher must accept an explicit
cast-site visibility policy/current module (or an explicitly projected
descriptor) and apply the same `member.islocal`/owner rule as ordinary method
lookup. Every checker path that can admit the new coercion must supply that
policy.

Keep visibility as an explicit matcher input rather than baking “public only”
into the satisfaction predicate. That shape is deliberately compatible with a
future extension that permits local Interfaces and local Interface methods,
similar to Go's local structural satisfaction; v1 still rejects those
declarations syntactically.

### 0.5 Keep ordinary wrapper identity equality

**Decision:** interface equality is ordinary nominal userdata identity.
Every evaluated concrete-to-interface conversion allocates a fresh wrapper, so
two separate conversions of the same record/union compare unequal. Aliases of
one interface value compare equal. Downcasting returns the original wrapped
reference.

Do not intern wrappers or special-case equality in v1. Document this
allocation-observable result.

### 0.6 Follow the existing `TValue`/`void *` boundary

The brief says interfaces are compatible with FFI `TValue`/`void*`. Existing
GC-backed Titan values are implicitly boxable into `TValue`, while a C
`void *` identity conversion is a **written cast**. The audit found that raw
`TValue -> arbitrary Titan type` is an overclaim in `compatible`, not an
existing implicit nominal conversion: ordinary direct record/union sinks
reject it, while recursive function/open-run callers can currently expose the
inconsistent edge. The central remediation removes that overclaim.

**Decision:** follow records/unions exactly and reuse their shared lowering:

- `I -> value` uses the ordinary gradual boxing injection; implicit
  `value -> I` uses a strict exact-wrapper projection, while written/Lua
  dynamic contexts use the same exact-wrapper-only
  `DynamicCoercionPlan(I)`;
- raw C `TValue -> I` is not direct; first convert to `value`, then use the
  context-selected exact-wrapper `value -> I` operation;
- `I` and `I? -> TValue` use ordinary whole-slot boxing, with option nil
  preserved by the central relation remediation; and
- `I -> C void *` is the existing explicit GC-identity cast and denotes the
  outer interface-wrapper `Udata *`, not the wrapped concrete object.

Do not silently broaden implicit C pointer conversion.

### 0.7 Reject empty interfaces in v1

The brief grammar requires one method followed by zero or more methods.

**Decision:** an interface must contain at least one method. Empty
universal interfaces are outside v1. Diagnose them explicitly rather than
letting a zero-byte vtable happen accidentally.

### 0.8 Use one `ProcessOutput` type and make the OS migration a clean break

**Decision:** add public `ProcessInput` and `ProcessOutput` records.
`Process.stdin` has the first type; both `stdout` and `stderr` have the second,
with a private discriminator and independent read state. Remove the old
`Process:write_stdin`, `close_stdin`, `read_stdout[_until]`, and
`read_stderr[_until]` forwarding methods. The brief says the pipe fields
replace them, and retaining both APIs would blunt the dogfood result.

Public Titan record fields are mutable. The manual must say that callers can
reassign these three references; v1 does not add readonly fields.

### 0.9 Publish interfaces in the type-only module namespace

The dormant `register_module_interface` branch anticipates finding an
Interface under a value-facing `Type.ModuleMember`, but that does not match the
current module namespace invariant:

- `Type.Module.members` drives expression member lookup and contains values or
  record/union namespaces that have a runtime surface; and
- `Type.Module.type_members` is invisible to expressions and contains
  compile-time type declarations with no module slot.

Unlike a record or union, an Interface has no constructor, static namespace, or
other value named `m.I`. Publishing it as a `ModuleMember` would therefore make
ordinary `Ast.VarDot` accept a descriptor as an expression and require
exceptions in every runtime-member consumer.

**Decision:** broaden `type_members` from “transparent aliases” to
“exported type-only declarations.” Store a public Interface descriptor there
directly. `Ast.TypeQualName` distinguishes the tagged entry:

- a `Type.Interface` entry resolves to `Type.Nominal(interface.name)`; and
- every other entry remains a transparent alias target.

Expression lookup continues to consult only `members`, so `m.I` is not a
runtime value. Import recovery first registers each direct Interface entry by
fqtn and then walks its method signatures for referenced nominals. This keeps
the value/type split intact without inventing a runtime module slot.

Audit every `members`/`type_members` consumer and update the manuals' narrower
“aliases only” wording. The nominal identity is the semantic contract;
`type_members` is the accepted storage namespace because Interface has no
runtime value member.

### 0.10 Preserve `interface` as a contextual C identifier

`interface` becomes a Titan keyword but is not a C keyword.

**Decision:** it remains legal anywhere the FFI accepts a source C identifier,
including C value members, fields, and qualified C type names. Add it to the
same contextual-name coverage as `repeat`, `type`, and `when`:

- raw `lexer.CNAME` and `lexer.NAMEDLABEL` still capture `interface`;
- the parser marks `c.interface`/qualified C-type uses with
  `_contextual_c_name`;
- the checker accepts those spellings only for actual C namespaces/owners; and
- ordinary Titan declarations still cannot use the reserved word as a name.

## 1. Outcome, scope, and non-goals

The feature delivers:

- non-local, top-level nominal language-interface declarations;
- one or more bodyless method signatures per interface;
- declaration-order method indices and named-argument metadata;
- one direct concrete-to-Interface coercion whose structural-satisfaction
  predicate uses Titan's directional callable adjustment rules;
- explicit checker-inserted wrapper construction at every coercible
  concrete-to-interface use;
- direct and adjusted native vtable entries;
- ordinary method calls, named calls, first-class bound methods, options,
  `value`, Lua calls, and concrete `is`/`as` downcasts;
- a two-uservalue `Udata` wrapper with a copied function-pointer array;
- source, DSO, regular archive, prefix-container, and standalone support;
- the shared compiled-module ABI 0.20 cutover described by §3.8;
- a `titan.io` module containing seven nominal interfaces;
- `fs.File`, `net.Connection`, and OS process pipes as initial implementers;
- a new chapter in **both** manuals, plus a standard-library IO chapter; and
- full parser/checker/coder/runtime/GC/metadata/packaging/stdlib coverage.

V1 does **not** add:

- local or nested interfaces;
- local interface methods;
- fields, constructors, static functions, method bodies, or default methods;
- interface embedding, inheritance, extension, intersections, or anonymous
  interface types;
- explicit `implements` declarations;
- any record/interface or interface/interface subtyping relation;
- any transitive or structurally lifted “implements” relation;
- whole-container or general callable lifting of the concrete-to-Interface
  coercion;
- dynamic discovery that a `value` holding a bare record implements an
  interface;
- conversion from one interface to another through the hidden concrete value;
- reflection over implementer names or vtable contents;
- wrapper interning, special equality, hashing, or ordering;
- whole-container or general callable adapters;
- C-compatible struct/vtable layout;
- a source-level vtable or unsafe interface construction API;
- readonly record fields for OS process pipes; or
- migration of an existing ABI-0.19 installation in place.

Debug-library or C-API mutation of userdata uservalues/payload opts out of
Titan's safety contract, as it already does for record, union, and Array
internals.

## 2. Normative language specification

### 2.1 Lexical and declaration syntax

`interface` becomes a reserved Titan keyword. Longer identifiers such as
`interfaces` and `interfaced` remain ordinary identifiers.

An interface declaration is allowed only at module top level:

```titan
interface Reader
  function read(): string?
  function read_until(delimiter: string, chop: boolean?): string?
end
```

The grammar is conceptually:

```text
interface-declaration =
    "interface" NAME
        interface-method
        { interface-method }
    "end"

interface-method =
    "function" NAME "(" parameter-list? ")" return-annotation?
```

Interface methods reuse the complete Titan callable signature grammar:

- fixed named parameters;
- a typed variadic parameter;
- zero, one, or multiple fixed results; and
- a flexible result tail.

They have no body and no individual `end`. There is no colon before the method
name: every member is necessarily a method, so a receiver marker would add no
information. A method declaration cannot be prefixed with `local`, and the
interface itself cannot be `local`.

An interface must declare at least one method. Method names must be unique
within the interface. Fixed parameter names must be dense and unique, exactly
as for callable declarations that support named calls. A method with a typed
variadic parameter retains the existing restriction on named-call syntax.

The parser produces one `Ast.TopLevelInterface` with an ordered list of
bodyless `Ast.InterfaceMethod` nodes. It does not synthesize top-level function
or method declarations.

### 2.2 Namespace, visibility, and nominal identity

Interfaces occupy the ordinary module type namespace alongside records,
unions, and type aliases. A declaration is visible throughout its combined
folder module under the same declaration-frontier rules as records/unions.
Imported interfaces are qualified by the import alias:

```titan
local io = import "io"
local input: io.Reader
```

An interface declaration is type-only:

- unqualified `Reader` and qualified `io.Reader` are type names;
- no record-style runtime namespace is created;
- `io.Reader` in an expression is rejected as “interface is a type, not a
  value” rather than becoming a table or constructor; and
- Lua `require "titan.io"` still returns the ordinary Titan module object, but
  that module does not expose a `Reader` value.

Like a type alias, an Interface may share its spelling with any ordinary value
symbol, including an import alias, module variable, or function (subject to the
existing conflicts within the value namespace). It may not share its spelling
with another Interface, a type alias, a record, or a union. Records/unions
occupy both namespaces because they own runtime constructors/statics;
Interfaces do not. The checker must therefore collect Interface conflicts in
the type namespace and must not reserve an Interface as an ordinary value
symbol.

The interface owner does create the interface metatable and Lua method entries;
those are implementation artifacts, not source-visible static members.

Each fully qualified interface name denotes one nominal type. Two distinct
interfaces are neither consistent nor coercible even when their ordered
method signatures are identical. Repeating the same method set in composite
IO interfaces therefore does not create inheritance:

```text
Reader             is neither consistent nor coercible with ReaderCloser
ReaderWriterCloser is not a subtype of Reader
```

A concrete value can be independently wrapped as either interface if it
implements both.

An ordinary Titan type alias may name an interface. It remains a transparent
alias for the same `Type.Nominal` and does not create a second interface
identity, metatable, vtable order, or wrapper representation.

### 2.3 Method signatures and structural satisfaction

For matching, project both an interface method and a concrete method to the
same self-removed closure type:

```lua
Type.Function(params, rettypes, false, varargtype, flexrettype)
```

A direct coercion plan from record/union `R` to Interface `I` exists when the
private satisfaction matcher proves, for every Interface method in declaration
order:

1. `R` has a cast-site-visible **method** with the same name;
2. the checker runs
   `callable_adjustment(project(concrete_method),
   project(interface_method), { aligned_coercions = false })`; and
3. the checker records the resulting exact entry or shape/gradual adjustment
   plan in declaration order.

This structural-satisfaction predicate is private to construction of the one
outer `R/U -> I` coercion. It is not a type relation, it is not transitive,
and it is never queried recursively for Array/Map/Option/Function components.
Every ordinary aligned method component must be gradually consistent; a
direct automatic coercion between the component types does not satisfy the
method.

Fields, record/union functions, union constructors, and module functions with
the same name do not satisfy a method. Extra concrete methods are irrelevant.
Interface parameter names are ignored for implementation matching. The
interface names are retained for calls:

```titan
interface PairConsumer
  function put(x: integer, y: integer)
end

record Swapped
end

function Swapped:put(y: integer, x: integer)
end
```

`Swapped` implements `PairConsumer`, but:

```titan
local p: PairConsumer = Swapped.new()
p:put{ x = 2, y = 3 }
```

passes positional values `2, 3`; the concrete method therefore receives
`y == 2` and `x == 3`. Names select positions from the interface signature,
not from the hidden implementer.

Callable adjustment retains Titan's existing argument/result shape rules.
For example, after replacing the obsolete `number` spelling with a current
Titan numeric type, this concrete method:

```titan
function R:foo(): float
  return 1.0
end
```

can implement:

```titan
interface I
  function foo(x: float, y: float): (...: value)
end
```

because the two surplus arguments are evaluated and discarded and the fixed
`float` result can feed the flexible `value` tail. This pair needs an
adjustment wrapper; it is not an exact vtable entry.

In particular, the outer Interface coercion does not lift through a method
result. This concrete method does **not** satisfy `Cloneable`:

```titan
interface Cloneable
  function clone(): Cloneable
end

record R
end

function R:clone(): R
  return self
end
```

If `R` is intended to satisfy the Interface, make the scalar conversion
explicit in the concrete method's own declared result context:

```titan
function R:clone(): Cloneable
  return self
end
```

The return statement performs one direct `R -> Cloneable` coercion. Method
matching then sees the exact `Cloneable` result; it does not derive
`()->R` to `()->Cloneable`.

No coinductive `R implements I` relation or recursive pair proof is needed.
A cache, if worthwhile, is only a memo of the complete direct matcher result
and must include the cast-site visibility domain. Never replay an owner-module
success that used a local method for an importer where that method is hidden.

A failed pair reports the first interface method in declaration order with a
specific reason: missing, inaccessible, or incompatible callable shape. Do not
emit an unordered table-iteration diagnostic.

### 2.4 Consistency, coercion, and conversion matrix

The outer concrete/interface operation is the source-to-target
`types.coercion(source, target, visibility)` plan. It is deliberately separate
from symmetric gradual consistency, whose repaired API is
`types.consistent(left, right)`. There is no subtype or consistent-subtype
relation between the concrete and Interface types.

| Source | Target | Relation and behavior |
|---|---|---|
| `I` | the same `I` | equal/consistent identity; no allocation |
| `I` | a different interface `J` | neither consistent nor coercible |
| implementing record/union `R` | `I` | coercible; construct a fresh wrapper |
| non-implementing record/union | `I` | not coercible; report the first method failure |
| `value` | `I` | gradually consistent; implicit projection is strict, while written/Lua dynamic coercion uses `DynamicCoercionPlan(I)`; both accept only an existing exact-`I` wrapper |
| `I` | `value` | gradually consistent boxed injection |
| C `TValue` | `I` | no direct relation; first convert to `value`, then exact-check an existing `I` wrapper |
| `I`/`I?` | C `TValue` | box the complete slot as for `R/U` and their options; preserve nil |
| `I` | C `void *` | explicit written GC-identity cast only |
| `I` | record/union `R` | no implicit relation; only the explicit downcast from §2.7 |

These are the audited central `TValue` rules for records/unions. Interfaces
must not treat raw `TValue` and nominal userdata pointers as interchangeable
or add dynamic structural discovery.

The checker must insert an annotated `Ast.ExpCast` for every successful
record/union-to-interface coercion. Leaving the expression unchanged would
pass the wrong representation to codegen. This applies to every ordinary
target-typed coercion sink, including:

- declarations and assignments;
- fixed and named arguments;
- returns;
- record fields and union payloads;
- Array elements and both Map keys and values checked directly against an
  interface type;
- module variable initializers; and
- generic-for yielded-variable bindings and the iterator's typed
  state/control/close setup where each finite scalar slot is adapted;
- finite scalar projections demanded from flexible results or typed `...`.

This list names the non-obvious sinks but is not a substitute for auditing
every `trycoerce`, `checkmatch`, open-run, and generic-call adjustment caller.
The accepted central relation-audit remediation defines how a real coercion is
distinguished from representation-preserving gradual consistency at those
seams.

These are statically typed Titan sinks. They do not authorize dynamic
conversion from a bare record/union to an Interface. For target `I`, the
central `DynamicCoercionPlan(I)` accepts only an existing wrapper with the
exact nominal `I` metatable. Written `value as/is I` and genuine-Lua
Interface-typed function formals, record/module fields, Array writers, and
other Lua-facing sinks all consume that same exact-wrapper arm. The present
arm of `I?` has the same rule; nil remains the ordinary optional case. A bare
`R/U` is rejected even when the checker would prove `R/U -> I` at a statically
typed Titan cast site.
Raw Lua Map writes remain outside this conversion machinery. Storing a bare
implementer into a Map viewed as `Map<K,I>` does not wrap it; the later strict
Interface read rejects the record/union value. That read uses the same strict
guard for an exact wrapper, a bare implementer, or any other payload regardless
of whether Titan or Lua wrote it.

The annotation carries the canonical interface descriptor, concrete
descriptor, ordered concrete-method mapping, and exact/non-exact result. The
coder must not rediscover implementation by an unordered lookup.

Do not add an Interface-specific container rule. Repaired gradual Array and
Map consistency remains pointwise and guards values at their eventual
observations. Because `R` and `I` themselves are not consistent, that rule
does not make `{R}` consistent with `{I}`:

```titan
local rs: {R} = ...
local is: {I} = rs             -- rejected: R and I are not consistent

local make_r: () -> R = ...
local make_i: () -> I = make_r -- rejected: coercion does not lift through
                               -- a Function result

local is2: {I} = { R.new() }   -- allowed; element is wrapped
```

To adapt a producer, put the scalar conversion in a real result context:

```titan
function make_i(): I
  return make_r()
end
```

Ordinary callable adjustment may still use gradual `value` components and
Titan's arity/tail shape rules. It must not admit an Interface wrapper
coercion, numeric conversion, Option introduction, or any other ordinary
automatic coercion in an aligned component slot.

A Map keyed by `I` may accept a satisfying concrete key through the same
ordinary assignment/coercion-plan path. Each evaluation creates a fresh wrapper, so
inserting with `m[r]` and later looking up with a separately evaluated `m[r]`
uses distinct keys and normally misses. Retaining `local i: I = r` and using
`m[i]` for both operations is stable. This allocation-observable result is
intentional, not a reason for a Map-key exception.

### 2.5 Options

Interfaces may be optional. These are explicitly named assignment plans, not
a generic structural lifting rule. The `R/U` rows explicitly compose the one
direct wrapper coercion, the same-`I` rows use existing Option
introduction/force, and the `value` row is a strict gradual projection:

| Source | Target | Behavior |
|---|---|---|
| `R` | `I?` | build an `I`, then wrap it as present |
| `R?` | `I` | force non-nil, then build `I` |
| `R?` | `I?` | nil propagates; a present `R` is wrapped as `I` |
| `I` | `I?` | ordinary present option |
| `I?` | `I` | ordinary force; nil raises |
| `value` | `I?` | strict implicit projection: nil propagates; a present value must already be an exact `I` wrapper |
| C `TValue` | `I?` | no direct plan; explicitly convert the complete slot to `value`, then apply the preceding row |

The option AST/coder path must retain the base interface-cast annotation. It
must not synthesize an undecorated `R -> I` conversion during code generation.
Neither `value` nor raw `TValue` dynamically discovers that a bare wrapped
record/union implements `I`.

Calling a method on `I?` uses the existing receiver auto-force behavior. A nil
receiver raises the ordinary option/type error before dispatch.

For concrete downcasts:

- `nil` in `I? is R` evaluates to `false`;
- a present `I? is R` checks the wrapped concrete value;
- `nil` in `I? as R` raises the ordinary nil/type-cast error; and
- a successful present downcast returns the exact wrapped `R`/union reference.

Written `as`/`is` otherwise follows Titan's deliberately narrow existing cast
relations rather than admitting every implicit option conversion. The one
general dynamic case is source `value`: `written_cast(value, T)` embeds the
same target `DynamicCoercionPlan(T)` used at a genuine Lua boundary:

- `I? as/is I` is the ordinary exact option unwrap/test;
- `I? as/is R/U` is the Interface-specific force-then-downcast above;
- `value as/is I?` accepts nil or an existing wrapper with the exact Interface
  metatable, never a bare implementing record/union;
- `R/U as/is I` is the statically checked Interface conversion/test; and
- source-option adaptation `R? as/is I` and target-option combinations such as
  `R as I?`, `R? as I?`, `I as R?`, and `I? as R?` remain inadmissible written
  casts;
- direct C `TValue as/is I` or `I?` remains inadmissible, as does direct
  `TValue as/is` an existing record/union; the central repair does not broaden
  Titan's written C-cast table. Use the explicit two-step
  `(tv as value) as/is I` instead.

Because `is` admits exactly the corresponding `as` relation, it follows the
same list and uses the non-raising predicate form of that dynamic plan. Tests
must cover every accepted and rejected row rather than assuming the implicit
option matrix also defines written casts.

### 2.6 Method calls and method values

Method lookup on `I` uses the interface's own method map and parameter names.
The receiver is evaluated exactly once and rooted before any argument
evaluation that can allocate or raise. Positional, named, variadic, flexible
return, result-discard, and nil-fill behavior follows ordinary Titan calls.

At runtime, an interface call:

1. reads the concrete module and concrete `self` from the wrapper;
2. reads the method pointer from the payload at the interface declaration
   index;
3. casts that pointer to the interface method's native ABI; and
4. invokes it with the concrete module, concrete `self`, and adjusted call
   operands.

The outer interface metatable is a type tag and Lua dispatch surface; it does
not select the implementation.

`obj:method` without a call creates an ordinary self-removed
`Type.Function`. It captures the interface wrapper. An exact function-value
call must use Titan's native fast path, not the Lua entry. Consequently the
closure's native pointer is a fixed bound-interface trampoline, not the raw
vtable entry: a vtable method entry still expects explicit `self`, while a
bound function value does not.

The native trampoline reads its captured wrapper, extracts the current
module/self/vtable slot, and dispatches. Its Lua trampoline inserts the
captured interface wrapper as the receiver before delegating to the interface
owner's coercive Lua method entry. Viewing that method value through a
non-exact but consistently related function type uses the repaired
Titan-generic strict stack entry appended to the bound closure, never that
coercive Lua entry.

### 2.7 `value`, `is`, and `as`

Boxing an interface as `value` stores the outer interface wrapper. Therefore:

```titan
local i: I = r
local v1: value = i
local i2 = v1 as I  -- succeeds; v1 holds an I wrapper

local v2: value = r
local i3 = v2 as I  -- fails; no dynamic implementation discovery
```

`value is I` and `value as I` use the exact-wrapper arm of the canonical
`DynamicCoercionPlan(I)`, identical to a genuine Lua Interface sink. It is an
explicit dynamic coercion, not a strict-consistency guard, but this particular
target still accepts only the exact outer metatable: the compiler cannot
manufacture a vtable when the static concrete type has been erased.

Although `I` is not consistent with concrete `R`, explicit `i is R` and
`i as R` are legal when `R` is a visible record/union type:

- inspect wrapper uservalue 1, not the outer interface metatable;
- compare the wrapped value's concrete metatable with `R`'s canonical
  metatable;
- `is` returns the comparison;
- successful `as` returns that exact wrapped `Udata *`; and
- failed `as` raises a diagnostic naming both source interface and target
  concrete type.

For an implementing `R`, `R as I` constructs a wrapper. The corresponding
`R is I` evaluates its source exactly once, allocates nothing, and returns
`true`. A non-implementing record/union is an inadmissible written cast and
therefore a compile-time `cannot cast` for **both** `as` and `is`; `is` is not
general compile-time structural reflection. `I is J`/`I as J` is allowed only
when `I` and `J` are the same nominal interface. Do not unwrap an interface and
dynamically rewrap it as another interface.

### 2.8 Allocation, equality, and lifetime

Each evaluated concrete-to-interface conversion allocates a fresh wrapper and
copies its pair vtable. There is no per-object cache. Ordinary interface
equality is therefore wrapper identity:

```titan
local a: I = r
local b: I = r
assert(a ~= b)
local c = a
assert(a == c)
assert((a as R) == r)
```

Equality admits only operands accepted by the separate symmetric
`comparable` policy. `I == R` and
`R == I` are both compile-time errors because the implicit coercion relation
is not consulted by equality. Callers must explicitly wrap `R` as `I`,
downcast `I` as `R`, or box both sides as `value` before comparing. Distinct
nominal Interfaces are likewise incomparable. Map indexing is different: it
is a target-typed coercion sink and can wrap a concrete key, with the
fresh-identity consequence described in §2.4.

Option lifting does not weaken this rule: `I? == R`, `R == I?`, `I? == R?`,
and both reversed forms are compile-time errors. Equality never forces an
option or allocates an Interface wrapper merely to compare it.

The wrapper strongly retains:

- the concrete owner module in uservalue 0, supplying the exact per-state
  module object required by the method ABI; and
- the wrapped record/union in uservalue 1.

Those roots make separate compilation safe when a consumer knows only the
interface and has no import path to the concrete defining module.
Native provider code remains callable because Titan's loader keeps DSO handles
open; uservalue 0 is not a DSO-unload mechanism. The module registry normally
also roots module objects, so lifetime tests should treat uv0 as correct state
provenance rather than claim it is the sole module root.

### 2.9 Lua-facing behavior

The declaring module owns one protected metatable per interface, shared by all
implementers in a Lua state. Its display identity is the fully qualified
interface type, not an implementer pair.

The metatable:

- exposes public interface methods through `__index`;
- rejects every assignment through `__newindex`;
- protects `__metatable`;
- has no fields, constructors, or static members; and
- never exposes the payload or wrapped concrete reference.

One generic Lua entry per interface method validates that argument 1 has the
correct interface metatable, applies the normal Lua/Titan argument boundary,
dispatches through the payload pointer, and boxes results using the interface
signature. An Interface-typed parameter accepts only an existing exact
Interface wrapper; the Lua entry never wraps a bare implementing record/union.
Calling an extracted method with the wrong receiver reports the interface and
method name.

All wrappers for one interface share this metatable even when their concrete
types differ. Lua's builtin `require "io"` remains unchanged; the Titan
standard module is loaded from Lua as `require "titan.io"`.

## 3. Runtime and ABI contract

### 3.1 Descriptor model and stable method order

Add these AST shapes:

```text
Ast.TopLevelInterface(loc, name, methods)
Ast.InterfaceMethod(loc, name, params, rettypes, flexrettype)
```

The existing parameter AST carries a possible typed variadic tail, so the
interface method node should use the same representation as callable
declarations rather than inventing a second signature shape.

Add:

```text
Type.Interface(name, methods)
```

`methods` is both:

- a dense declaration-ordered array; and
- a name map whose keys point to the exact same `Type.Method` descriptor
  objects.

Reuse `Type.Method(fqtn, name, params, rettypes, varargtype, flexrettype,
paramnames)`. Do not add an index field to every method descriptor. The
zero-based payload index is the method's position in the Interface array; the
`Type.Interface` constructor may derive a non-serialized decoration after
construction/rehydration.

Method order is ABI-significant and must survive serialization. Serialize the
dense ordered method list exactly once, as `Type.Union.variants` does; the
`Type.Interface` constructor rebuilds the string keys to the exact same
`Type.Method` objects. Equality and closed validation prove that this hybrid
in-memory list/map projection has no extra, missing, or divergent key.
Constructor input must be numeric-list-only: reject any preexisting string or
other non-list key before deriving the map, so hostile wire input cannot be
silently overwritten during canonicalization. Direct validator tests may
mutate a constructed object afterward to prove missing/wrong/extra derived
keys are rejected.
Parameter names serialize for named calls but are excluded by the projected
`Type.Function` comparison used for implementation/exactness.

At source level, the complete descriptor is registered under its fully
qualified name in `types.registry`. In a public module interface, publish the
descriptor directly in `Type.Module.type_members` under its source name, per
§0.9. This is a nominal type-only declaration, not a transparent alias:
qualified type resolution returns `Type.Nominal(interface.name)` for this
tagged entry, while expression-member resolution never sees it.

Recovered direct Interface entries register in `types.registry` before their
method signatures are traversed. They create no public-prefix slot because
`Type.Module.members` contains no Interface entry at all.

### 3.2 Wrapper layout

Add a runtime function-pointer storage type with an explicit supported-toolchain
cast boundary, for example:

```c
typedef void (*TitanInterfaceMethod)(void);
```

The concrete typed pointer is converted through `titan_cast_func`; do not cast
through data `void *` or assume ISO C permits incompatible function-pointer
calls.

An interface value is:

```text
Udata
  metatable -> canonical interface metatable
  uv[0]     -> concrete owner module Udata
  uv[1]     -> wrapped record/union Udata
  payload   -> nmethods copied TitanInterfaceMethod entries
```

Construction order is:

1. evaluate and root the concrete value;
2. resolve/root the concrete module object and target Interface metatable,
   completing all registry lookups and possible errors;
3. allocate `luaS_newudata` with two uservalues and exact payload bytes;
4. immediately rebase `_base` and anchor the half-built wrapper;
5. attach the already resolved interface metatable;
6. store and back-barrier the concrete module;
7. store and back-barrier concrete `self`; and
8. `memcpy` the already initialized static pair vtable into the payload.

`luaS_newudata` is a stack-relocating allocation. Keep the source root by stack
offset, mark the context `uses_base_off`, and rebase `_base` immediately after
allocation before anchoring or rereading any reserved slot.

The copied payload contains no GC pointers. The two uservalues are the complete
traced ownership edge. Use `sizeof(the_pair_vtable)` for allocation and copying
instead of open-coded `nmethods * sizeof(pointer)` arithmetic. The current
parser list limit applies to parameter/expression lists, not to an interface's
repeated method declarations; do not claim that it bounds this payload. The
generated static array and `luaS_newudata` size path must fail safely if an
impractically large source exhausts implementation resources.

### 3.3 Pair obligations and vtable initialization

The first annotated cast for a canonical `(concrete fqtn, interface fqtn)` pair
in one translation unit records one ordered obligation. Repeated casts reuse
it. Separate translation units may independently emit equivalent private pair
vtable/adapters; there is no global registry object for a pair.

For each interface method:

- if the projected concrete and interface `Type.Function` values are exactly
  equal, store the concrete native method entry;
- otherwise emit one private static adjustment wrapper and store it; and
- never decide exactness from `Type.Method`, whose owner/name metadata differs.

The static array is initialized during module initialization because imported
native method symbols may be dynamically recovered. Initialization happens
after imported method/bound symbols are loaded and before any module variable
initializer or root initializer can construct an interface.

Both module-init paths must initialize the process-static pointer array:

- the path that creates a fresh per-state module object; and
- the path that recovers an already registered module object for another
  import/init request.

Initialization is idempotent and contains only process-stable code pointers.
Do not put the pair vtable in a Lua registry entry or module upvalue.

Current generated initialization creates module variables before publishing
function-type tags. That already lets a top-level bound method/lambda capture a
null tag and silently fall back to generic dispatch. Move function-tag
initialization ahead of module variables as part of this ABI change, then
initialize pair vtables before module variables too. Add a regression for
existing record bound methods/lambdas as well as the new top-level bound
interface method, so this ordering fix is not interface-only folklore.

### 3.4 Adjustment-wrapper ABI

An interface entry has the native method ABI of the interface signature. Its
hidden operands include `lua_State *`, the concrete module, `_fn` closure
pointer, and concrete `self`, followed by fixed/variadic inputs and result
outputs. Every call **through a vtable payload entry passes `_fn = NULL`**.
Neither an interface-owner Lua closure nor a bound-interface closure has the
capture layout of the selected concrete method/adapter and may be forwarded as
that operand.

An adjustment wrapper is a private static native function with exactly that
ABI. Conceptually it is:

```titan
function SyntheticInterfaceMethod(<interface parameters>)
  return self:concrete_method(<interface arguments and ...>)
end
```

It emits no Lua entry, public symbol, callable metadata member, source
declaration, or closure. It does receive a private trace-name mapping: use a
stable user-facing spelling such as
`<interface>:<method> [adapter for <concrete>:<method>]`, so a conversion
failure never leaks an opaque generated C symbol. Its body uses the established
expression-list adjustment machinery for:

- evaluated-and-discarded surplus arguments;
- nil-filled missing arguments;
- gradual injections/projections and strict guards in the required direction;
- discarded surplus results;
- fixed result projection and output parameters;
- typed variadic input; and
- flexible result production/consumption.

When a typed variadic or flexible open run is converted element-by-element,
reuse/retain the caller-owned traced source range so every not-yet-converted
source survives allocations performed by earlier conversions. Every converted
GC-bearing destination then lives in a separate parallel traced stack range
until the concrete call/result handoff is complete. `TitanVarg*.args`, C
temporaries, and raw source/destination descriptors or userdata payload memory
are not GC roots. Preserve element order and open-run count across every
allocation or raising conversion.

The adapter's `_mod` is unconditionally the module that owns the concrete
record/union, exactly as for a direct call to that concrete method. Synthetic
lowering therefore interprets every concrete-method module slot and private
nominal identity in that owner's layout. The translation unit that happens to
emit the private adapter has no runtime module identity and must not substitute
its own caller/cast-site slots.

Ordinary conversion or nominal-metatable helpers used by the elaborated body
may still push, allocate, and relocate the Lua stack. Mark such adapter
contexts `uses_base_off`, address reserved roots by offsets, and rebase `_base`
after every helper before reading a saved slot. A coder assertion should make
accidental use of the emitting translation unit's private module layout a
compiler bug. It must not turn the already specified two-uservalue contract
into a third context object or reject an otherwise valid callable adjustment.

### 3.5 Interface owner artifacts

For every declared interface, its module emits:

- code to publish/recover the canonical interface metatable by registry key;
- the protected method-name `__index` map and rejecting `__newindex`;
- one generic Lua dispatch entry per method;
- one fixed native bound-interface trampoline per method;
- one bound-Lua trampoline per method;
- one bound-strict Titan-generic light C function per method;
- the self-removed function-type tag used by bound closures; and
- trace-name entries for exported native trampolines where they can appear in
  a Titan traceback.

Keep the two module roles distinct in generic Lua dispatch. The Lua closure's
module upvalue is the **interface owner** and supplies the private identities
needed to check/box the public interface signature. Wrapper uservalue 0 is the
**concrete owner** and is passed only to the selected concrete/adapter entry.
Neither may be substituted for the other.

Cross-module bind sites recover all three bound-entry symbols, extending the
existing record/union native/Lua trampoline machinery with the strict entry.
Extend
external-symbol collision preflight, DSO `loadsym`, static archive wiring, and
`direct_native_modules` accounting consistently. In particular:

- an imported exact pair entry explicitly records the concrete method owner
  and symbol in `tlcontext.functions`; and
- an imported bound Interface method explicitly records the Interface-owner
  native trampoline in `tlcontext.functions` and its Lua trampoline in
  `bound_luas`, plus the strict entry in a parallel role-aware registry (or a
  generalized bound-entry registry that keeps Lua and strict symbols
  distinct).

Those records must feed `direct_native_modules`, standalone link inputs, and
the executable-context protocol probe even though no ordinary direct-call AST
mentions the symbols. Verify that public-prefix reconstruction adds no
Interface slot.

The interface metatable is created even if the declaring module itself never
constructs the interface. A casting/consumer module may recover it through the
existing per-state nominal-metatable path after the owner module initializes.

### 3.6 Separate-compilation contract

The required four-module case is:

```text
api       declares interface I
consumer  imports api and exports use(i: api.I)
provider  declares record R and its methods
bridge    imports api + provider + consumer, converts R to I, calls consumer.use
```

`consumer` must compile and run without `provider` in its source import graph.
The bridge-created wrapper retains the provider module and concrete value.
Consumer dispatch uses only the serialized `api.I` descriptor, interface
metatable, ordered payload slot, and method ABI.

Exercise this topology with source modules, individual DSOs, regular static
archives, a multi-module prefix provider, and a standalone executable. Include
both an exact method and a non-exact adjustment method.

### 3.7 Serialized module-interface validation

`Type.Interface` is legal only as a direct entry of its owning
`Type.Module.type_members` map. It must not be nested inside a transparent
alias target, a value-facing `Type.ModuleMember`, or another value descriptor.
`Type.Method` remains illegal as a free value-facing descriptor and becomes
legal inside its owning Interface in addition to the existing record/union
member-map contexts.

The closed validator must prove:

- Interface fqtn equals `<module>.<member-name>`;
- no locality marker is present;
- the method list is dense and nonempty;
- string keys and numeric entries form one exact list/map projection;
- method names are nonempty and unique;
- every method owner fqtn equals the Interface fqtn;
- method locality is false;
- fixed parameter/result arrays are dense;
- parameter names are dense, unique, and exactly fixed arity;
- vararg/flexible tails and every nested value type are valid;
- no C FFI or local nominal escapes through a public signature;
- no descriptor wrapper is smuggled into a value-facing graph; and
- serialization round-trips to the canonical ordered shape.

There is no arbitrary parser method-count bound in v1. Generated payload-size
arithmetic must still reject `size_t` overflow/allocation impossibility before
allocating or copying a vtable.

Hostile metadata must fail while the candidate provider is still the
diagnostic subject, before codegen or symbol loading trusts method indices.
Transitive nominal-owner recovery walks every interface method signature.

### 3.8 Shared ABI 0.20 cutover

Language interfaces change serialized schemas, userdata conventions, exported
method symbols, metatable protocols, and callable dispatch. The prerequisite
relation repair changes the Array proxy from one to two user values and adds
the strict trailing entry to every Titan function closure. Advance all of
these together from ABI 0.19 to **ABI 0.20**.

The work may be split into two PRs for review, but that split does not create
two ABI transitions. Stack or otherwise coordinate the PRs, require clean
rebuilds when validating each head, and do not publish an ABI-0.20 release,
provider set, or compatibility promise from the intermediate layout. The
final ABI-0.20 tree contains the relation/Array/function and Interface changes.
When split, the prerequisite relation PR owns the one mechanical
0.19-to-0.20 marker/path advance. The Interface PR inherits, completes, and
validates ABI 0.20; it does not advance to another version.

Advance together:

- `driver.TITAN_VER` and `TITAN_VER_SUFFIX`;
- `TITAN_VER`/history in `titan-runtime/titan.h`;
- Make's `TITAN_ABI_VERSION`;
- versioned path/environment suffix `_0_20` (not generated C symbol names);
- `TITAN_PATH_0_20`;
- active install path `lib/titan/0.20`;
- runtime loader defaults and generated shims;
- Make/LuaRocks/installer active paths;
- workflow environment, cache keys, cleanup, canaries, and support scripts;
- fixtures and ABI/static-provider specs; and
- current-version language/implementation documentation.

Treat 0.19 as the preserved previous ABI. Use a fresh/clean active-0.20 prefix,
leave installed 0.17/0.18/0.19 trees untouched, reject 0.19 before metadata
rehydration, and do not add an in-place migration layer. The Linux preparation
assertion changes from “contains 0.19, not 0.18” to “contains 0.20, not 0.19.”

Do not blindly replace historical ABI mentions: descriptions of the union ABI
transition and older retained layouts remain historical facts.

## 4. Compiler architecture and exact change map

### 4.1 Mandatory reading gates

This feature crosses nearly every compiler boundary. Reading the manuals is a
phase gate, not an optional review aid.

Before changing compiler Lua or generated/runtime C, every implementation
agent and every reviewer assigned to that work must read, at minimum:

- `doc/implementation/index.md`;
- `doc/implementation/ast-typedecl.md`;
- `doc/implementation/lexer-parser.md`;
- `doc/implementation/checker.md`;
- `doc/implementation/codegen-overview.md`;
- `doc/implementation/codegen-constructs.md`;
- `doc/implementation/values-and-gc.md`;
- `doc/implementation/named-arguments.md`;
- `doc/implementation/variadic-parameters.md`;
- `doc/implementation/flexible-returns.md`;
- `doc/implementation/lua-interop-internals.md`;
- `doc/implementation/unions.md`;
- `doc/implementation/driver.md`;
- `doc/implementation/static-compiled-modules.md`; and
- `doc/implementation/multi-module-libraries.md`.

An agent working on a narrower phase may then reread the relevant subset, but
must not substitute a source skim for this initial implementation-manual pass.
Review prompts must list the same relevant chapters and ask the reviewer to
check the implementation against their stated invariants.

The language chapter `doc/language/interfaces.md` must be drafted and reviewed
with the core feature before stdlib dogfooding begins. Every implementation or
review agent that edits Titan source under `titan/` must first read:

- `doc/language/index.md`;
- the new `doc/language/interfaces.md`;
- `doc/language/types.md`;
- `doc/language/functions.md`;
- `doc/language/named-arguments.md`;
- `doc/language/flexible-returns.md`;
- `doc/language/variadic-parameters.md`;
- `doc/language/option-types.md`;
- `doc/language/expressions.md`;
- `doc/language/records.md`;
- `doc/language/unions.md`; and
- the specific standard-library chapters for the files it will edit.

For IO dogfood that final subset is
`standard-library-fs.md`, `standard-library-net.md`,
`standard-library-os.md`, and `async-io.md`, plus the new
`standard-library-io.md` once its doc-first draft exists. A reviewer must read
the updated chapters, not only the pre-change versions.

Dogfood is implementation work, so its agents/reviewers also read the relevant
implementation chapters before editing: FS and OS process work reads
`doc/implementation/libuv-runtime.md`; net work reads
`doc/implementation/libuv-networking.md`; and provider/installer/packaging work
reads `doc/implementation/driver.md`,
`doc/implementation/static-compiled-modules.md`, and
`doc/implementation/multi-module-libraries.md`. Phase prompts must name these
files explicitly.

### 4.2 Lexer, syntax errors, AST, and parser

Touch:

- `titan-compiler/lexer.lua`;
- `titan-compiler/syntax_errors.lua`;
- `titan-compiler/ast.lua`;
- `titan-compiler/parser.lua`;
- `spec/lexer_spec.lua`;
- `spec/parser_spec.lua`;
- `spec/checker/c_ffi_spec.lua`; and
- the existing coder C-FFI/named-argument specs.

Work:

1. Add `INTERFACE` with the same exact-keyword/longer-identifier discipline as
   `record` and `union`. There is no C-keyword allowlist to update:
   `lexer.CNAME = C(identifier)` and `NAMEDLABEL` already accept every
   identifier spelling. Preserve those generic contextual captures so
   `c.interface`, C fields/types, and named C prototype parameters remain
   usable only in valid C contexts, while ordinary `NAME` rejects the new
   Titan keyword.
2. Add the two AST constructors from §3.1. Keep the nested method node
   bodyless; do not reuse a top-level method node and fill it with synthetic
   fields.
3. Parse one or more interface method signatures between `interface NAME` and
   its one `end`.
4. Reuse existing fixed parameters, typed varargs, return-list, and flexible
   return grammar/captures. Preserve locations on the interface, method,
   parameters, and result annotations.
5. Reject `local interface`, a `local function` interface member, colon
   spelling, method bodies, fields, record functions, statics, nested
   declarations, a missing method, and missing interface `end` with
   interface-specific syntax labels where possible.
6. Keep parameter-list limits and parser stack behavior identical to other
   callable declarations.
7. Add `io = "titan.io"` to `standard_imports`, with a parser assertion that
   `import "io"` desugars only in Titan source. This does not change Lua's
   builtin module.

Do not let a permissive repeated-method rule accept an empty interface and
defer it silently. If the PEG is clearer with a zero-or-more capture, the
checker must still issue the normative nonempty diagnostic, and both layers
need tests.

### 4.3 Type descriptors and central relations

Touch primarily `titan-compiler/types.lua` and `spec/types_spec.lua`.

Work:

1. Add `Type.Interface(name, methods)` to the typedecl schema and a constructor
   that installs the ordered list/name-map projection.
2. Add a helper that projects `Type.Method` to its self-removed
   `Type.Function`. Use it for record, union, and interface methods instead of
   open-coding slightly different shapes.
3. Add one deterministic interface-implementation matcher. Its successful
   result contains the ordered concrete descriptors and exactness flags; its
   failure contains the first ordered reason.
4. Keep the matcher a direct, non-transitive predicate for one canonical
   `(concrete fqtn, interface fqtn, visibility domain)` pair. It compares each
   projected method once through `callable_adjustment`; it does not recursively
   ask whether component records/unions implement component Interfaces. A
   cache, if used, stores only the complete result for that exact key.
5. Give the matcher an explicit method-visibility policy/current module. Do
   not trust a full source descriptor in global `types.registry` to mean its
   local methods are visible to an importer.
6. Use repaired symmetric `types.consistent(left, right)` solely for gradual
   consistency. Add direct structural `R/U -> I` wrapper construction only as
   one branch of plan-producing
   `types.coercion(source, target, visibility)`.
7. Give the Interface coercion/matcher an explicit cast-site visibility
   context rather than consulting checker globals. Thread it through the
   explicitly named Option/interface coercion plans and every direct scalar
   coercion sink; do not thread it into general consistency or ordinary
   callable component matching.
8. Let the dedicated interface-method matcher call
   `callable_adjustment(concrete_source, interface_target,
   { aligned_coercions = false })`. Preserve repaired Array/Map gradual
   consistency and callable shape adjustment, but reject aligned
   record/Interface, numeric, Option, C, and other coercion-only pairs.
   Record the exact shape/gradual plan that an adjustment wrapper executes;
   do not add Interface-only “bounded” relations.
9. Use projected `types.equals` for exact/no-wrapper classification.
10. Extend equality, tostring, serialization, first-C-FFI traversal,
   referenced-nominal traversal, and every exhaustive Type tag switch.
11. Keep `Type.Interface` a declaration descriptor. Runtime values continue to
    have `Type.Nominal(interface fqtn)`, so `is_gc`,
    `has_tvalue_representation`, C identity casts, options, and ordinary
    storage remain nominal. Remove or reconcile the currently vestigial
    `Type.Interface` branch in `types.is_gc`; do not let declaration wrappers
    appear as value types.
12. Preserve deterministic serialization by declaration order and sorted
    module type-member keys.

Complete the separate
`.agents/plans/type-relations-soundness.md` audit/remediation before this
feature changes these relations. That work owns the exhaustive raw-caller
inventory and repairs any existing mismatch between “gradually compatible”
and “requires an emitted conversion.” Interface work then adds only the
direct outer `coercion(R/U, I, visibility)` plan and its explicit cast
annotation. Its private satisfaction predicate is not exported as subtyping,
not consulted by consistency, and not recursively lifted through compound
types.

Add direct unit tests for parameter-name independence, exactness,
source/target direction, all unusual shape/gradual argument/result rules,
visibility-shaped descriptors, existing Array/Map consistency, and rejection
of coercion-only method slots.

### 4.4 Checker declaration stages and module types

Touch primarily `titan-compiler/checker.lua` and add
`spec/checker/interfaces_spec.lua`.

Extend all declaration classifiers:

- `toplevel_name`;
- duplicate marking and reserved top-level names;
- type-alias/nominal conflict collection;
- the nominal signature pass;
- `checkbodies` signature validation;
- module-interface construction;
- local-nominal and C-FFI export rejection;
- recovered nominal registration; and
- any AST/type traversal used by closure analysis or diagnostics.

Declaration order:

1. Collect Interface names with aliases/records/unions in the type namespace so
   conflicts are stable, while leaving them out of the ordinary value-symbol
   reservation. This permits a same-spelled module variable/function.
2. In the nominal signature pass, resolve one Interface's bodyless method
   signatures, construct its complete dense descriptor, and register it. There
   are no constructors and no partially built descriptor is serialized.
   Forward/mutual references remain `Type.Nominal` fqtns, following the current
   record/union pattern; signature collection must not eagerly dereference or
   match them.
3. After all Interface and record/union descriptors exist, run the ordinary
   deferred nominal-existence/export validation over every signature.
4. Register concrete record/union methods in the existing callable pass.
5. Check module variables and bodies only after all Interface and concrete
   method signatures are available.

This preserves module-wide nominal visibility, mutual nominal references, and
the current later-import/module-variable frontier. Interface signatures may
refer to imported public nominals and aliases under the same export rules as
other public callable signatures.

In `makemoduletype`, add each public Interface descriptor directly to
`type_members[name]`. Extend the `Type.Module.type_members` contract from
aliases-only to exported type-only declarations. `TypeQualName` returns
`Type.Nominal(interface.name)` for a `Type.Interface` entry and returns the
stored type directly for an alias entry. Expression `VarDot` remains
`members`-only, but on a miss it must consult the type namespace solely to emit
the required “interface is a type and has no runtime value” diagnostic.
Unqualified expression lookup does the analogous diagnostic when no
same-spelled value symbol exists. Never attach an Interface descriptor as a
value `_decl`. Complete `register_module_interface` so it registers all direct
Interface entries first and then traverses their method signatures.

Audit every module-namespace consumer rather than patching only these named
seams: equality/serialization/validation, referenced-nominal and C-FFI walks,
loader rehydration, qualified type and expression lookup, coder public-prefix
layout, Lua module entries, static metadata, tests, and both implementation
manual chapters that currently define `type_members` as aliases-only.

### 4.5 Cast insertion, implementation diagnostics, and options

Repaired `assignment_adjustment` is the central implicit insertion seam;
the checker may continue to route it through its `trycoerce` helper. A successful
direct `R/U -> I` coercion must always return an `Ast.ExpCast` with:

- `_implicit_coercion = true`;
- source/target resolved `Type.Nominal` values;
- `_interface_conversion` containing the canonical pair and ordered mapping;
  and
- enough option/base metadata for codegen to avoid recomputation.

Do not rely on the current rule “compatible but not coercible means leave the
expression unchanged.” Interface adaptation is a direct,
representation-changing coercion, so the assignment plan must contain the
annotated cast.

C `TValue` boundaries are not redesigned here. Implement the central
remediation from `.agents/plans/type-relations-soundness.md` first:
Interface/Option-to-`TValue` boxes the complete slot and preserves nil, while
raw `TValue -> I` is not direct. A caller converts raw `TValue` to `value`,
then the context-selected `value -> I` operation checks the exact outer
Interface metatable: an implicit assignment uses the strict projection, while
written `as` uses `DynamicCoercionPlan(I)`. Neither performs structural
discovery of a bare concrete value.

Use the ordinary `trycoerce` path for declarations, assignments, returns,
arguments, named arguments, fields, union payloads, Array elements, Map keys
and values, and module initializers. Add a focused assertion per sink in
checker tests. `isconst` must treat an implicit interface cast around an
otherwise constant record/union constructor as a permitted module initializer
while preserving evaluation/allocation order.

When a named `Option` coercion plan decomposes or synthesizes a base cast, copy
or reconstruct the checked `_interface_conversion` mapping. Never ask codegen
to rerun the structural matcher, and do not expose a generic "map any
coercion through Option" rule. Add explicit annotations for:

- present conversion;
- nil propagation;
- forced source option; and
- optional `is`/`as`.

Spell those option annotations per §2.5. In particular, do not broaden written
casts to arbitrary target-option conversions while making implicit
`R? -> I?` conversion and nil-preserving `I? -> TValue` boxing work.

Extend explicit cast checking only where specified:

- implementing `R/U as I` and `R/U is I`;
- same-interface identity;
- `I is/as visible R/U` downcast; and
- `value is/as I` exact-wrapper checking.

Keep `I -> R/U` out of consistency and automatic coercion, and keep
different-interface casts rejected. Diagnostics must distinguish
missing/incompatible methods, erased concrete type in `value`, and failed
runtime downcasts.

### 4.6 Method call and reference checking

The current receiver paths explicitly accept Record/Union owners. Extend them
to resolve `Type.Nominal` owners whose registry descriptor is Interface.

For calls:

- auto-force `I?` as for other optional nominal receivers;
- resolve only the Interface method map;
- retain its parameter names for named argument ordering;
- annotate the stable method index;
- run existing argument/result demand;
- evaluate the receiver once; and
- preserve existing named-call restrictions on variadic signatures.

For `obj:method` references:

- derive the self-removed projected function type;
- retain the Interface descriptor and stable method index;
- annotate use of the interface bound trampolines; and
- keep visibility/error wording interface-specific.

The implementation matcher and ordinary interface call checker share the
projection helper but have different jobs: the former ignores parameter names
and compares two signatures; the latter uses the interface names to rearrange
one call.

### 4.7 Coder context, metatables, and declarations

Touch primarily `titan-compiler/coder.lua`, with small runtime declarations in
`titan-runtime/titan.h` and helpers in the appropriate runtime C file.

Extend:

- nominal-kind switches that currently enumerate Record/Union;
- `type2metatable` with kind `"interface"`;
- metatable ownership/recovery;
- AST declaration passes;
- method call and method-reference lowering;
- explicit/implicit cast lowering;
- boxing/unboxing and `is` lowering;
- function symbol/import/loadglobal registries;
- collision/preflight sets;
- public-prefix reconstruction's explicit no-Interface-slot case;
- trace-name registration; and
- exhaustive codegen/analysis visitors.

Add an Interface declaration emitter that creates owner artifacts but no
record-style namespace table and no module-member switch entry. Ensure a
module containing only interfaces still initializes and is Lua-loadable even
though it has no public runtime fields.

Reuse ordinary nominal-metatable and module-slot helpers. Adapter lowering
interprets `_mod` as the concrete owner's module layout regardless of the
emitting translation unit; no caller/casting-module identity helper or extra
context registry is introduced. Existing helpers must continue to validate
the low-level representation they actually consume and fail malformed/missing
entries with a Titan diagnostic. Do not expose a public Lua API for
constructing or mutating wrappers.

### 4.8 Pair collection and generated-code ordering

Pair obligations can arise in:

- top-level variable initializers;
- function/method/static bodies;
- lambdas;
- module root initializers; and
- named Option/open-element scalar conversion plans carrying a direct
  concrete-to-Interface cast.

Collect obligations before final C declarations and module-init text are
sealed. Checker elaboration first builds fully typed synthetic wrapper IR (or
an equivalently explicit per-slot callable plan). Those wrappers contain
shape actions and gradual guards only; they cannot introduce nested
`R/U -> I` coercions. A pre-emission scan of the ordinary AST and its named
Option/open-element plans collects every already annotated pair, deduplicates
by canonical pair key, and emits in deterministic fqtn order with methods in
interface order. No fixed-point "implements" closure is needed. Coder must not
call consistency/coercion or discover a new semantic obligation while
emitting C.

While collecting, explicitly enqueue imported concrete exact-method owners and
imported Interface bound-trampoline owners into `tlcontext.functions`/
`bound_luas`; do not assume the ordinary direct-call visitor will discover
these hidden vtable/closure edges.

Generated ordering:

1. forward declarations for all native methods, interface entries, bound
   trampolines, and adjustment wrappers;
2. static pair-vtable declarations;
3. ordinary and synthetic native bodies;
4. module-interface metadata/constants;
5. in the fresh-module setup block: `LOADMODULES1`/module setup,
   `LOADGLOBALS`, nominal/interface metatable setup, function-type tags, pair
   vtables, canonical closures/statics, `INITNAMES`, top-level variables, then
   the module root initializer; and
6. in the existing-registry setup guarded by `if (!_initialized)`:
   `LOADMODULES2`, `LOADGLOBALS`, function-type tags, and pair vtables (plus
   any hidden symbol/name setup required by that branch).

Do not initialize pair tables unconditionally on every existing-registry
return. Each branch initializes them only after its imported symbols and tags
exist. `INITNAMES` must precede any user initializer that can raise through an
adapter. This deliberately fixes the fresh branch's current
`INITVARS`-before-`INITFUNCTAGS` order. Add generated-C structure assertions
for both branches plus a `DEPTH_PROBE` runtime case for top-level
record/interface bound methods and lambdas rather than depending only on
result equality or runtime luck.

### 4.9 Exact interface calls and wrapper construction

Add one lowering for annotated interface construction:

- evaluate and root the source exactly once;
- select the concrete owner module object exactly as an ordinary direct
  record/union method use does in that context;
- in an adjustment wrapper, take that object from the wrapper's first
  uservalue and interpret it as the concrete owner's `_mod`, never as the
  emitter/caller/cast-site module;
- resolve/root the target Interface metatable, completing every registry
  lookup/error before allocation;
- allocate the wrapper, immediately rebase `_base`, and anchor it;
- attach the pre-resolved metatable;
- store the concrete module and `self` uservalues with barriers;
- copy the canonical pair array; and
- leave one typed `Udata *` result.

Add one lowering for direct interface method calls:

- evaluate/root receiver before arguments;
- load both uservalues without exposing them to Lua;
- load the payload slot after validating compile-time index bounds;
- cast to the interface method ABI with `titan_cast_func`;
- pass `_fn = NULL` to the selected concrete/adapter payload entry;
- use the ordinary exact native result-storage path; and
- preserve try/catch/finally cleanup and stack-slot restoration.

Do not dispatch through the coercive Lua entry from Titan code. Direct and
exact bound calls use native entries; non-exact branded bound-function calls
use the repaired strict Titan-generic stack entry. Add tests that would fail
if either Titan path runs the coercive entry.

Parameterize the existing Lua-entry generator rather than cloning all of its
argument/result/error handling. The interface variant replaces the final
static-native call with payload lookup and a direct typed invocation. Its
coercive Lua entry consumes `DynamicCoercionPlan` for each target formal; its
strict bound-function entry consumes gradual guards, receives the original
bound closure as a hidden argument, and invokes the bound-native trampoline
with that closure as `_fn`.
The bound-native trampoline then reads the captured Interface wrapper and
calls the payload entry with `_fn = NULL`. The direct Interface Lua entry also
calls the payload entry directly. Do not insert a redundant exported
“interface dispatch” native frame.
The bound-native, bound-Lua, and bound-strict trampolines need cross-module
export/recovery as applicable. Direct Titan calls inline dispatch, while pair
vtables and adjustment wrappers remain translation-unit private.

### 4.10 Adjustment wrappers

Build synthetic wrapper IR during checking from resolved descriptors rather
than reparsing invented Titan source. Reuse the repaired
call/result-demand, callable-shape, and gradual-guard planners there, with
ordinary aligned component coercions disabled, and freeze the fully typed
result before coder collection. Give the wrapper a constrained context:

- hidden concrete-owner module and `self` are bound explicitly;
- the concrete method is already resolved;
- interface parameters/results define the native signature;
- the concrete call uses the ordered adjustment mapping;
- no Lua entry/closure/public member is emitted.

Coder consumes only the elaborated calls, casts, nil-fill/discard operations,
open-run projections, and pair annotations. It may assert their consistency
against descriptor identities, but it must not recreate the former
`compatible`/`coerceable` logic or rerun `types.consistent`,
`types.coercion`, `types.callable_adjustment`, or implementation matching.

The elaborated open-run plan retains the existing traced source range until all
source elements are converted and includes a separate traced destination range
for every GC-bearing converted element, released only after handoff. Never
treat raw `TitanVarg*.args`, result descriptors, or an adapter C buffer as a
root.
Adapter codegen also carries `uses_base_off` and explicit post-helper `_base`
rebasing for every helper that can relocate the stack. Its module-slot
operations use the concrete owner's layout; the emitting translation unit does
not become a runtime module context.

Test the entire callable matrix, not only fs's nil-filled `read`:

- fewer/more fixed parameters;
- nil-acceptable and forced missing parameters;
- gradual `value` injections/projections and wrong-value failures;
- rejection of numeric, Option, C, and concrete/Interface component
  coercions;
- fewer/more fixed returns;
- zero-result and discarded-result cases;
- typed variadic input in both directions;
- flexible results with finite and open consumers;
- an interface-typed argument accepted as `value`; and
- consistent Array/Map/function slots and their audited delayed runtime
  guards.

The exact method path must not pay for or emit a wrapper.

### 4.11 Interface bound methods

Generate one native/coercive-Lua/strict-Titan bound trampoline set per
Interface method in the owner module. Use stable names with Titan's existing
symbol mangling plus the owner fqtn, method name, and bound-entry role. Do not
append `_0_20`; ABI rejection and provider selection, not per-symbol version
spelling, gate these symbols.

At a bind site, create a six-upvalue closure using the repaired ordinary
function-value convention. The fixed brand occupies the fourth header slot
and the strict entry is the final trailer:

```text
upvalue[0] = interface owner module
upvalue[1] = self-removed function-type tag
upvalue[2] = bound-interface native trampoline pointer
upvalue[3] = fixed opaque Titan-function brand
upvalue[4] = captured interface wrapper
upvalue[5] = bound-interface strict Titan-generic entry as an LCF TValue
```

The canonical self-removed function-type tag stored in upvalue 1 remains the
exact native-call identity. Non-exact dispatch instead requires at least five
upvalues and compares the raw pointer bits in upvalue 3 with
`TITAN_FUNCTION_CLOSURE_BRAND`. The brand is the same fixed ABI sentinel for
source and compiled providers; it requires no reverse registry publication or
provider-order protocol.

The native trampoline's function-value ABI reads upvalue 4 and dispatches the
indexed vtable method with explicit concrete `self`. Its incoming `_fn` is the
bound closure used only to read that upvalue; it passes `_fn = NULL` to the
payload entry. The Lua trampoline
inserts upvalue 4 as argument 1 and calls the interface generic entry. Export
and recover these owner artifacts plus the strict entry across DSOs/archives
just like existing bound method trampolines. A non-exact Titan call pushes
upvalue 5 as the VM callee and the original bound closure as its hidden first
argument; after strict argument conversion, the entry passes that original as
`_fn` to the upvalue-2 bound-native trampoline, which reads the wrapper. It
must not delegate through the coercive Lua trampoline.

Tests must prove:

- exact function-type calls hit the upvalue-2 native fast path;
- consistently related non-exact calls use the upvalue-5 strict path and reject
  values that only the dynamic boundary would coerce;
- source, DSO, and archive closures carry the fixed brand in upvalue 3 and
  foreign C closures lacking that sentinel remain on the Lua path;
- receiver lifetime is retained;
- an imported-interface-only bind site works; and
- wrong Lua receiver manipulation cannot bypass metatable checks.

### 4.12 Runtime checks, GC, and errors

Extend nominal get/check/set paths so Interface nominal values remain ordinary
`Udata *`. `value -> I` checks the outer metatable; raw `TValue -> I` is not a
direct relation and must first become `value`. `I`/`I? -> TValue` boxes the
complete slot, preserving nil. `I -> R/U` downcast reads and checks uservalue
`1`. Option nil handling must occur before checking or dereferencing the
wrapper.

GC tests must force collection:

- immediately before construction and immediately after complete
  metatable/uservalue/payload initialization, with the source rooted across
  allocation;
- with only the interface retaining concrete `self` (the module registry
  remains an independent module root);
- with only a bound method retaining the interface;
- during argument adjustment and flexible-result allocation;
- under incremental and generational collection; and
- after the concrete source variable becomes unreachable.

The current construction sequence has no allocating/raising operation between
anchoring the fresh wrapper and storing both immutable uservalues. Prove that
ordering and both barriers with generated-C assertions instead of inventing an
unreachable “old wrapper receives young values” or post-anchor fault case. Use
hard-memory/fault paths before allocation and in surrounding conversions where
existing helpers support them. A failed allocation/conversion must leave the
Lua stack and protected-boundary state consistent and never publish a
half-initialized wrapper.

Runtime errors should name:

- expected interface and found Lua type/metatable;
- method and interface on a bad Lua call;
- target concrete type on failed downcast;
- nil option force;
- malformed/uninitialized internal vtable only as a compiler/runtime bug.

### 4.13 Driver, loader, providers, and static metadata

The static metadata container format can remain unchanged; the serialized type
graph and ABI marker change.

Touch and test:

- `titan-compiler/driver.lua`;
- `titan-compiler/staticmetadata.lua` if an exhaustive tag/schema assumption
  exists there;
- `titan-runtime/titan.c`;
- `titan-runtime/titan.h`;
- `titanc` standalone native-input/protocol integration for hidden pair/bound
  symbol owners;
- DSO and archive loader specs;
- source/DSO/archive nominal-owner recovery; and
- external-symbol collision detection.

The driver validator must use the closed schema in §3.7 for DSO and archive
metadata equally. Provider selection remains root-major and format-pass based.
An ancestor provider missing an unrelated interface key remains a clean
nonclaim; a claimed malformed Interface is terminal.

Add interface cases to:

- source-interface recovery;
- direct `.so` import;
- exact regular `.a` import;
- multi-module `.so` and `.a` prefix containers;
- DSO/archive interface equality comparisons;
- static target derivation and executable protocol probes; and
- hostile metadata tests.

No `.tmm`, child DSO, symlink, hard link, or implicit import of every key in a
container is introduced.

## 5. Standard-library dogfooding

### 5.1 New `titan.io` module

Add `titan/io.titan` containing exactly these seven public nominal interfaces:

```titan
interface Reader
  function read(): string?
  function read_until(delimiter: string, chop: boolean?): string?
end

interface Writer
  function write(data: string)
end

interface Closer
  function close()
end

interface ReaderWriter
  function read(): string?
  function read_until(delimiter: string, chop: boolean?): string?
  function write(data: string)
end

interface ReaderCloser
  function read(): string?
  function read_until(delimiter: string, chop: boolean?): string?
  function close()
end

interface WriterCloser
  function write(data: string)
  function close()
end

interface ReaderWriterCloser
  function read(): string?
  function read_until(delimiter: string, chop: boolean?): string?
  function write(data: string)
  function close()
end
```

These are seven independent nominal interfaces. There is no embedding or
declared relationship. Document the concrete implementer matrix:

| Concrete type | Structurally implements | Adjustment |
|---|---|---|
| `net.Connection` | all seven | exact |
| `fs.File` | all seven | nil-fill `read`; discard `write` result |
| `os.ProcessInput` | `Writer`, `Closer`, `WriterCloser` | exact |
| `os.ProcessOutput` | `Reader` | exact |
| `net.Server` | `Closer` | incidental exact implementation |
| `timer.Ticker` | `Closer` | incidental exact implementation |

The last two are an intentional consequence of structural matching and need a
test/documentation note so later method changes do not alter the relation
unnoticed.

### 5.2 `fs.File`

Change the public facade to:

```titan
function File:read(max_bytes: integer?): string?
function File:read_until(delimiter: string, chop: boolean?): string?
```

Semantics:

- omitted/nil `max_bytes` uses `READ_CHUNK_BYTES` (64 KiB);
- an explicit nonpositive value retains the current error;
- a value above the libuv/native bound is rejected before narrowing;
- `read(max)` never returns more than `max`, including retained excess;
- when retained excess is already available, `read(max)` returns up to `max`
  immediately without topping it up from a new native read; any remainder
  stays retained;
- strings are binary-safe;
- an empty delimiter is rejected;
- `read_until` consumes through the first delimiter, includes it by default,
  and chops it only when `chop == true`;
- bytes after the delimiter are retained for the next read;
- EOF with accumulated bytes returns the tail; empty EOF returns nil;
- EOF is not permanently sticky for a file that may grow;
- cancellation or an error after consuming bytes restores them to the file's
  excess before propagating; and
- fs errors remain per-operation rather than becoming stream-sticky.

Do **not** implement `File:read_until` as a high-level loop of separate
`uv._fs_read` calls. Another Task's write, flush, or close could interleave
between those FIFO operations. Extend `titan/uv/file.titan` so one logical
`FsOperation` retains its queue position while resubmitting native reads,
analogous to the existing partial-write state machine.

The low-level work should:

- add retained excess to `uv_file`;
- add read-until/delimiter/chop/accumulation state to `FsOperation`;
- expose one focused `uv._fs_read_until(file, delimiter, chop)` facade entry
  for `titan.fs`, while `_fs_read` also consumes the shared retained excess;
- reuse folder-local byte search/slice helpers rather than importing
  `titan.string`;
- use an internal 64-KiB native submission size for read-until, accumulate
  multiple chunks without repeated whole-prefix string concatenation, and
  guard `total + #chunk` against overflow before allocating the final result;
- restore consumed data on cancellation/error;
- service existing excess within the same queued operation, never
  synchronously ahead of older queued work; and
- refresh the `titan.uv` public fixture/projection for that intentional
  `_fs_read_until` addition and any required signature change, without
  exposing the operation state itself.

The excess-only path must be a real owner-free head completion, not a fake
zero-byte libuv request or timer. Refactor `submit_file_head`/its caller so it
can return a `DriveControl` for the Task that just yielded and can schedule the
ordinary drive for an already-waiting queued Task. Dequeue/advance the file
head before delivering the result. A read-until whose retained bytes lack the
delimiter keeps the same head operation and submits another native read; a
plain read returns the available prefix immediately as specified above.

`File.write` continues to return the number of bytes. `Writer.write` returns no
values, deliberately exercising result-discard adjustment. `File.read`'s
optional parameter deliberately exercises nil-fill adjustment for
`Reader.read()`.

### 5.3 `os.Process` pipe records

Use this public/private shape:

```titan
record ProcessInput
  local handle: uv.uv_process_t
end

record ProcessOutput
  local handle: uv.uv_process_t
  local stdout: boolean
  local excess: string
  local reading: boolean
end

record Process
  local handle: uv.uv_process_t
  stdin: ProcessInput
  stdout: ProcessOutput
  stderr: ProcessOutput
end
```

Methods:

```titan
function ProcessInput:write(data: string)
function ProcessInput:close()

function ProcessOutput:read(): string?
function ProcessOutput:read_until(delimiter: string,
                                  chop: boolean?): string?

function Process:wait(): ExitStatus
function Process:kill(signal: string)
```

Move the existing per-output excess/reader-lock behavior into each
`ProcessOutput`. Keep the low-level `titan.uv` process API unchanged unless the
move exposes a real ownership bug. Holding the low-level process handle
directly avoids a Process/pipe reference cycle and means an interface-wrapped
pipe retains the native owner.

`spawn` creates all three pipe records and stores them in the Process. Remove
the old forwarding methods and migrate:

- `write_stdin` to `stdin:write`;
- `close_stdin` to `stdin:close`;
- `read_stdout[_until]` to `stdout:read[_until]`; and
- `read_stderr[_until]` to `stderr:read[_until]`.

Preserve all existing FIFO, close, cancellation, terminal tail, sticky
read-error, independent stdout/stderr lock, wait, kill, and cleanup behavior.
Update `communicate` only if it uses the public forwarding surface; its public
signature/semantics do not otherwise change.

### 5.4 `net.Connection`

No public implementation change is expected after correcting `chop` to
`boolean?`. Add casts/calls through all seven interfaces, including at least
one composite interface and a bound method. Preserve the existing independent
reader lock, retained excess, sticky EOF/error, cancellation, write FIFO, and
close behavior.

### 5.5 Ten-root provider and installer

Use this canonical order everywhere:

```text
coroutine uv async timer io fs net os peg string
```

Update all four Make lists:

- `STDLIB_MODULES`;
- `STDLIB_ROOTS`;
- `STDLIB_TITAN_SOURCES`; and
- `STDLIB_SHIMS`.

The standard image now contains:

- ten logical modules/protocols;
- exactly ten archive metadata keys;
- ten generated Lua shims; and
- eleven DSO openers: bare `luaopen_titan` plus ten logical openers.

Add `io` to `scripts/stdlib_installer.lua`'s canonical module list. Its loops
must validate, back up, publish, roll back, and restore all ten shims and the
exact ten-key archive. Preserve the commit order: shims/dSYM, archive, DSO
last. The existing bootstrap/legacy-complete/complete-pair predecessor states
remain, now in active ABI 0.20.

The rockspec has no per-module manifest entry to add; ensure `titan/io.titan`
is in the source rock and the source-only post-install compiler invocation
receives all ten roots.

Audit exact lists/counts and active paths in:

- `Makefile`;
- `.gitignore` (add the generated `/titan/io.lua` shim);
- `scripts/stdlib_installer.lua`;
- `spec/libuv_build_spec.lua`;
- `spec/rockspec_spec.lua`;
- `spec/stdlib_installer_spec.lua`;
- `spec/support/async_stdlib.lua`;
- `spec/support/ci_stdlib_snapshot.sh`;
- `spec/support/ci_libuv_mode_smoke.sh`;
- sanitizer/production smoke scripts;
- `.github/workflows/ci.yml`;
- `AGENTS.md`/repository instructions; and
- current packaging/driver/libuv manuals.

Do not convert historical nine-root statements inside an old ABI history
paragraph into claims about the past having ten roots.

### 5.6 Dogfood fixtures and production proofs

Refresh:

- `spec/fixtures/stdlib/titan_stdlib_types.lua` for `titan.io`, interfaces, fs,
  and OS schemas;
- `spec/fixtures/libuv/titan_uv_types.lua` only for actual `titan.uv` public
  schema changes;
- OS production smoke source/Lua assertions;
- bundled/system static production smokes; and
- archive/DSO exact metadata expectations.

The production Titan smoke must import `io` and call:

- a `net.Connection` through an exact composite interface;
- an `fs.File` through `ReaderWriterCloser`, exercising nil-fill and
  result-discard adapters; and
- `Process.stdin` through `WriterCloser` plus stdout/stderr through `Reader`.

Run that proof against the installed DSO and archive-backed validation image,
not only source modules. Lua packaging smoke must load `require "titan.io"` and
also prove `require "io"` is still Lua's builtin table.

Keep all stdlib behavior suites outside LuaCov. If a new
`spec/stdlib/io_spec.lua` is added, explicitly classify it in
`spec/support/ci_test_groups.sh`; otherwise extend the existing fs/net/os
suites.

Measure the new checker/coder Interface suites under the grouped commands
before fixing their CI shard. Keep lightweight semantic cases in the core
compiler shard; put genuinely compile-heavy adjustment/provider cases in the
existing heavy/isolated ownership files or explicitly classify a topical
heavy file. Preserve the producer/consumer time budgets and `.luacov`'s
compiler-only collection contract. If dogfood exposes a compiler coverage gap,
add a small focused compiler case rather than covering a library behavior
suite.

## 6. Documentation deliverables

### 6.1 New language chapter

Add `doc/language/interfaces.md` and link it from
`doc/language/index.md`. It is normative for dogfood agents and must cover:

- declaration grammar and nonempty/public-only limits;
- type-only module namespace behavior;
- nominal interface identity and the direct structural-satisfaction
  predicate;
- cast-site-visible method policy;
- directional callable adjustment and ignored parameter names;
- exact versus adjusted methods;
- source-to-target concrete/interface coercion, separate from gradual
  consistency and explicitly not subtyping;
- repaired pointwise Array/Map consistency and delayed callable guards, with
  no lifting of Interface or other automatic coercions, including the
  fresh-wrapper Map-key consequence;
- implicit `R/U -> I` and written `R/U as I` wrapper construction, contrasted
  with allocation-free `R/U is I` and exact-wrapper-only dynamic checks that
  never construct;
- named, variadic, flexible-result, direct, and bound method calls;
- options;
- `value`, `TValue`, and explicit `void *`, including that written
  `value as/is I` and genuine Lua Interface sinks share the same
  exact-wrapper-only dynamic-coercion arm;
- concrete `is`/`as`;
- wrapper allocation, equality, and lifetime;
- Lua behavior, including the exact-wrapper-only rule for every
  Interface-typed Lua sink;
- separate compilation; and
- all v1 non-goals.

Examples must include:

- two nominal interfaces with identical shapes remaining neither consistent
  nor coercible;
- the swapped parameter-name named-call case;
- the unusual extra-argument/flexible-result implementation;
- rejection of a concrete `clone(): R` for Interface `clone(): I`, followed by
  the accepted form whose concrete method itself declares `clone(): I`;
- `value` holding I versus bare R;
- Lua passing an existing I wrapper versus a bare implementing R to an
  Interface formal;
- option nil behavior;
- two wrappers of one R comparing unequal; and
- the four-module api/consumer/provider/bridge topology.

### 6.2 New implementation chapter

Add `doc/implementation/interfaces.md` and link it from
`doc/implementation/index.md`. Cover:

- AST and `Type.Interface`/`Type.Method` shapes;
- declaration staging and nominal type-only publication;
- the direct, visibility-sensitive structural-satisfaction predicate and
  `coercion(concrete, interface, visibility)` plan;
- the explicit absence of record/Interface subtyping, transitive
  implementation, and compound coercion lifting;
- cast annotations and deterministic pair-obligation collection;
- concrete-owner `_mod` adapter invariant independent of the emitting
  translation unit;
- Udata layout, allocation order, barriers, and vtable copying;
- exact and adjusted entry ABIs;
- direct, coercive-Lua, strict Titan-generic, and bound-method dispatch,
  including the fixed brand in upvalue 3, captured wrapper in upvalue 4, and
  final strict LCF trailer;
- the central `DynamicCoercionPlan(I)` shared by written `value as/is I` and
  Lua-facing Interface sinks, distinct from strict Array/Map/callable
  observations;
- metatable ownership/recovery;
- concrete downcasts and exact `value` checks;
- closed serialized-schema validation;
- source/DSO/archive separate compilation;
- external symbols and public-prefix effects;
- ABI 0.20; and
- failure/GC behavior.

Remove or replace the current statement in
`doc/implementation/values-and-gc.md` that `Type.Interface` has no constructor.

### 6.3 Existing language chapters

Update at least:

- `doc/language/index.md` and current version text;
- `doc/language/grammar.md`;
- `doc/language/types.md`;
- `doc/language/functions.md`;
- `doc/language/named-arguments.md`;
- `doc/language/flexible-returns.md`;
- `doc/language/variadic-parameters.md`;
- `doc/language/option-types.md`;
- `doc/language/expressions.md`;
- `doc/language/records.md`;
- `doc/language/unions.md`;
- `doc/language/modules.md`;
- `doc/language/lua-interop.md`;
- `doc/language/arrays-maps.md`;
- `doc/language/static-compiled-modules.md`;
- `doc/language/multi-module-libraries.md`; and
- `doc/language/philosophy.md`/roadmap wording.

Add and link `doc/language/standard-library-io.md`. Update
`standard-library-fs.md`, `standard-library-net.md`,
`standard-library-os.md`, `standard-library-timer.md`, and `async-io.md` for
concrete implementers and the API changes. State that OS pipe fields are
mutable references, and record the incidental `timer.Ticker -> io.Closer`
implementation on Ticker's own API page.

### 6.4 Existing implementation and repository docs

Update current behavior in:

- `doc/implementation/ast-typedecl.md`;
- `doc/implementation/lexer-parser.md`;
- `doc/implementation/checker.md`;
- `doc/implementation/codegen-overview.md`;
- `doc/implementation/codegen-constructs.md`;
- `doc/implementation/values-and-gc.md`;
- `doc/implementation/named-arguments.md`;
- `doc/implementation/variadic-parameters.md`;
- `doc/implementation/flexible-returns.md`;
- `doc/implementation/lua-interop-internals.md`;
- `doc/implementation/error-handling.md`;
- `doc/implementation/coroutines.md`;
- `doc/implementation/dense-arrays.md`;
- `doc/implementation/driver.md`;
- `doc/implementation/static-compiled-modules.md`;
- `doc/implementation/multi-module-libraries.md`;
- `doc/implementation/libuv-runtime.md`;
- `doc/implementation/libuv-networking.md`;
- `doc/implementation/string-library.md`;
- `doc/implementation/lpeglabel-embedding.md`; and
- `doc/implementation/folder-modules.md`.

Also update the finalized top-level `doc/async-with-coroutines.md` specification
where it states the active provider path or module count. Run an explicit
repository-wide ABI/path/root-count search and classify every hit as current or
historical; broad wording here is not a substitute for that audit.

Update README feature/roadmap/version statements, repository instructions, and
any current “nine roots/keys/shims” or “ten openers” statement. Preserve
historical ABI narratives.

## 7. Test plan

### 7.1 Lexer and parser

Extend `spec/lexer_spec.lua` and `spec/parser_spec.lua` with:

- exact `interface` keyword recognition and longer identifiers;
- contextual `c.interface` C-member/C-type spelling and named-label escape
  behavior, with `_contextual_c_name` rejected outside C context;
- one and several methods;
- fixed, zero-result, multi-result, typed variadic, and flexible-result
  signatures;
- preserved fixed parameter names/locations;
- declaration-order AST;
- `io` short-import desugaring;
- duplicate method names reaching a stable checker error;
- empty interface;
- local interface and local member;
- colon member spelling;
- method body or per-method `end`;
- field/static/constructor-like members;
- nested interface;
- missing name, parentheses, result type, and final `end`; and
- a large method list proving the parser does not inherit the unrelated
  expression-list bound.

Parser snapshots/assertions should inspect the new AST nodes directly rather
than accepting any tree that happens to typecheck.

Extend `spec/checker/c_ffi_spec.lua` and the existing end-to-end coder
C-FFI/named-argument coverage with C typedefs, fields, module members, and
prototype parameters named `interface`. These cases prove that the generic
`CNAME`/`NAMEDLABEL` path survives reserving the Titan keyword; matching
ordinary Titan declarations remain syntax errors.

### 7.2 Types and checker

Add `spec/checker/interfaces_spec.lua`; keep low-level constructor/relation
tests in `spec/types_spec.lua`.

Descriptor/relation coverage:

- ordered Interface list/name map identity;
- equality, tostring, dense-list-only serialization, constructor-rebuilt keyed
  projection, and round-trip order;
- nonempty and duplicate canonicality;
- same-interface identity and distinct-interface nominal rejection;
- record and union implementation;
- missing method, non-method collision, inaccessible method, and incompatible
  signature diagnostics;
- extra concrete methods ignored;
- interface/concrete parameter names ignored for matching;
- a directional variance case that fails if the projected callable
  `callable_adjustment(concrete_method, interface_method)` source/target
  operands are
  swapped;
- interface names retained for named calls;
- exact versus adjusted mapping;
- cast-site-visible local record/union and local method behavior;
- imported descriptor unable to use omitted local methods;
- rejection of `R:clone(): R` for an Interface method `clone(): I`;
- acceptance when the concrete method itself declares `clone(): I` and its
  body performs the direct scalar conversion;
- no recursive/transitive implementation obligations are created;
- `value` in parameters/results;
- cast-site-visible local nominal/C-FFI adaptation through `value`;
- fixed argument/result surplus and nil-fill;
- typed variadic/flexible callable adjustment;
- repaired pointwise Array/Map gradual consistency and checked reads;
- shared dynamic-plan rejection of a bare implementing record/union for
  written `value as/is I`, an Interface-typed Lua function formal,
  record/module field, Array element, and present `I?` value, alongside
  acceptance of an existing exact `I` wrapper in every one of those contexts;
- rejection of callable result/parameter slots that differ only by numeric,
  Option, C, or concrete/Interface coercions;
- allowed Array-element/Map-value literal adaptation;
- concrete-to-Interface Map-key insertion/lookup producing fresh unequal
  wrappers, plus retained-Interface-key stable lookup; and
- deterministic first-failing-method diagnostics.

Cast-insertion coverage must inspect `Ast.ExpCast._interface_conversion` at
every scalar sink:

- local/module declarations;
- assignments;
- fixed and named call arguments;
- returns;
- record fields and union payloads;
- Array elements and both Map literal keys and values;
- module initializers;
- generic-for result bindings and iterator state/control/close scalar slots;
- finite projections from flexible results and typed `...`;
- explicit `R as I`; and
- all four implicit source/target Option combinations.

Also cover:

- no allocation annotation for same-I conversion or `R is I`;
- `I` and nil/present `I? -> TValue` box the complete slot with exactly-once
  evaluation, matching existing record/union targets;
- raw `TValue -> I/I?` is rejected at direct, argument, return, and option
  sinks, while `TValue -> value -> I/I?` uses the exact-wrapper run-time check;
- direct written `TValue is/as I/I?` and record/union targets remain rejected,
  while the explicit two-step through `value` works;
- `I is/as R/U` accepted only for visible concrete nominals;
- implementing `R/U is/as I` accepted, non-implementers rejected for both;
- every accepted/rejected source/target Option written-cast row from §2.5;
- `I -> R/U` ordinary assignment rejected;
- different-interface `is/as` rejected;
- `value -> I` accepted as a runtime exact check but not implementation
  discovery;
- one cross-context table proving `value as/is I`, Lua function arguments,
  Lua record/module writes, and Lua Interface Array writes accept/reject the
  same exact wrapper/bare implementer/nil/wrong-nominal inputs;
- interface method calls/references and `I?` receiver forcing;
- named order from the Interface descriptor;
- variadic named-call rejection;
- public Interface signature rejection for C FFI/local nominal types;
- Interface conflicts with aliases/records/unions but coexists with a
  same-spelled import/value/function in either source order, without an error
  overwriting the canonical descriptor;
- type-level `m.I` success and expression-level `m.I` diagnostic; and
- direct `type_members` publication and no runtime `members` entry/slot.

### 7.3 Code generation, dispatch, GC, and Lua

Add `spec/coder/interfaces_spec.lua` for end-to-end behavior. Keep focused
existing-regression cases in `spec/coder/bound_methods_spec.lua`,
`closures_spec.lua`, `backtrace_spec.lua`, and `type_tests_spec.lua` where that
ownership is clearer.

Core construction/dispatch:

- exact record and exact union slots;
- multiple concrete types sharing one interface metatable;
- multiple wrappers from one concrete value;
- declaration-order slots independent of concrete map iteration;
- receiver-before-argument evaluation and exactly-once side effects;
- repeated casts deduplicating one pair table per TU;
- exact paths emitting no adjustment wrapper;
- direct Titan calls bypassing Lua generic entries;
- static function-pointer array copied into each payload;
- supported common function-pointer cast round trip under warning-clean C99;
- same pair in two translation units;
- two independent Lua states using one code image/static pair table;
- no DSO unload assumption violation;
- imported exact concrete owners and imported bound Interface owners appear in
  `tlcontext.functions` and both bound stack-entry registries,
  `direct_native_modules`, standalone link inputs, and executable protocol
  probes even without an ordinary direct-call AST edge.

Adjustment matrix:

- extra/missing fixed arguments;
- nil-fill success and runtime force failure;
- extra/missing/discarded fixed results;
- zero-result Interface method versus result-returning concrete method;
- gradual `value` boundary injections/projections;
- compile-time rejection of numeric, Option, C, and
  concrete-to-Interface component conversions;
- `value` narrowing to a nominal;
- local C-FFI/local-nominal concrete slots adapting through `value` with the
  proven concrete-owner module context;
- typed variadic input, including empty and nonempty runs;
- flexible results with zero, finite, and open demand;
- collection during GC-bearing variadic/flexible element conversion, proving
  the retained source range and parallel traced destination roots;
- Option nil propagation and present conversion;
- consistent Array/Map/function/open-run values following the audited generic
  boundary without a bogus representation-changing cast;
- `{R} -> {I}`, `Map<K,R> -> Map<K,I>`, `() -> R` to `() -> I`, and an
  Interface method component `R` to `I` all rejected without wrapper
  synthesis.

Method values:

- direct interface method call;
- exact bound method fast path;
- non-exact consistently related function-value call through the strict
  trailing entry, including a case rejected by Lua-only coercion;
- imported-interface-only bind site;
- captured wrapper/module/self lifetime;
- top-level bound-interface initializer with `DEPTH_PROBE`;
- existing top-level bound record method and lambda tag regressions after
  `INITFUNCTAGS` moves; and
- coercive Lua bound trampoline inserting the correct receiver.

Downcast/boxing/equality:

- `value` containing I succeeds as I;
- `value` containing bare R fails as I;
- written `value as/is I` has exact acceptance parity with every Lua-facing
  Interface sink because both lower the same `DynamicCoercionPlan(I)`;
- `I` and nil/present `I?` box through `TValue`, while raw `TValue` reaches
  Interface only through the checked `value` boundary;
- explicit `I -> C void *` equals the wrapper identity, not concrete Udata;
- `I is/as` matching and nonmatching record plus union;
- optional nil/present downcasts;
- `R is I` evaluates once and allocates nothing;
- non-implementing `R is/as I` fails at compile time;
- `I == R`, `R == I`, and every optional lifting/reversed form from §2.8 fail
  at compile time without allocation;
- two `R -> I` casts compare unequal; aliases compare equal;
- one retained Interface wrapper works as a stable Map key while repeated
  concrete-to-key coercion constructs unequal wrappers and therefore misses;
- successful downcast has identity with the original concrete object.

Lua surface:

- metatable shared for one Interface across implementers;
- direct and extracted/bound method calls and result adjustment, with every
  generated Interface Lua entry applying the same target
  `DynamicCoercionPlan` to formals as ordinary exported functions and
  record/union method entries;
- an Interface-typed Lua argument accepts an exact wrapper and rejects a bare
  implementing record/union;
- Lua assignment to an Interface-typed module/record field and Lua write to an
  Interface Array follow the same exact-wrapper-only rule;
- a non-Titan Lua callable result entering an expected `I`/`I?` slot follows
  that same dynamic plan, accepting an exact wrapper or optional nil and
  rejecting a bare implementer;
- `I?` accepts nil or an exact wrapper from Lua, never a bare implementer;
- a bare implementer written through raw Lua Map mutation is rejected on the
  later typed Interface read rather than being retroactively wrapped, and the
  same strict read result holds when Titan wrote the identical payload through
  a `value` view;
- extracted method called with right/wrong self;
- protected metatable;
- all writes rejected;
- missing members;
- no fields/statics/constructor exposed;
- `require "titan.io"` works; and
- builtin `require "io"` remains unchanged.

GC/failure:

- incremental and generational full collections;
- source concrete value remains rooted across wrapper allocation;
- collection immediately before construction and after complete immutable
  construction;
- generated-C assertions prove both uservalue barriers and no
  allocation/raise between anchor and stores;
- only wrapper retains concrete self (without claiming it alone retains the
  registry-rooted module or DSO handle);
- only bound closure retains wrapper;
- collection during constructor arguments, adapter conversions, and traced
  variadic/flexible open-run conversion;
- allocation failure before wrapper allocation and failures in surrounding
  conversions;
- error/finally/raise through exact and adjusted dispatch;
- Lua stack relocation around bound/generic calls and allocating adapter
  helpers, proving `uses_base_off`/post-helper rebasing; and
- no half-built reachable wrapper on failure.

Backtrace coverage in `spec/coder/backtrace_spec.lua` must deliberately fail
inside an adjustment conversion and assert the selected stable descriptive
adapter name. Raw mangled adapter symbols must not leak. Exact dispatch should
not grow an artificial generic/interface-dispatch frame.

Generated-C assertions should inspect only stable contracts:

- two uservalues;
- `sizeof(pair_vtable)` allocation/copy;
- source-root offsets and `_base` rebasing immediately after
  `luaS_newudata`;
- both barriers;
- direct versus adapter slot target;
- imported symbols before vtable initialization;
- both fresh/existing-registry setup blocks initialize pair tables after their
  loads/tags and never on an ordinary initialized return;
- Interface metatable/tags, pair tables, and `INITNAMES` before module
  variables; and
- function tags before a top-level bound closure is created.

Do not overfit whitespace or temporary-variable spelling.

### 7.4 Module-interface and provider coverage

Per repository test ownership:

- extend `spec/union_interface_spec.lua` with hostile serialized
  `Type.Interface` schemas; do **not** create a competing
  `interface_interface_spec.lua`;
- extend `spec/checker/so_rehydration_spec.lua` for recovered Interface
  descriptors and nominal-owner walks;
- extend `spec/coder/so_import_spec.lua` for dynamic Interface use;
- extend `spec/checker/static_compiled_modules_spec.lua` for static nominal
  constraints;
- extend `spec/coder/static_compiled_modules_spec.lua` for archive-backed
  adjustment and native validation;
- extend `spec/driver_spec.lua` for root-major source/DSO/archive claims,
  occupied paths, cache behavior, and malformed claims;
- extend `spec/staticmetadata_spec.lua` only if its bounded binary-container
  parsing has an exhaustive metadata/schema assumption affected by Interface;
- extend `spec/coder/multi_module_libraries_spec.lua` for paired
  DSO/archive/prefix-container publication; and
- extend `spec/coder/multi_module_grouping_spec.lua` or
  `multi_module_path_runtime_spec.lua` for the four-module topology where
  appropriate; and
- extend `spec/driver_spec.lua` plus
  `spec/coder/folder_modules_spec.lua` for an Interface declared in one folder
  constituent, implemented/converted in another, with real-file duplicate and
  mismatch diagnostics.

Hostile schema cases include:

- Interface outside a direct owning `type_members` entry;
- Interface nested inside an alias target or smuggled into value `members`;
- wrong owner fqtn/member key;
- empty/sparse method list;
- preexisting string/non-list constructor input key;
- post-construction extra/missing/wrong derived keyed projection;
- duplicate method names;
- wrong descriptor tag or owner;
- local Interface/method marker;
- sparse/duplicate/wrong-arity parameter names;
- malformed nested option/function/nominal;
- escaped free `Type.Method`;
- C FFI/local nominal in public signature;
- recursive legal graph; and
- ABI 0.19 rejection before any Interface decoding/symbol load.

The separate-compilation matrix must run exact and adjusted calls with
`consumer` knowing only `api.I`, while provider `R` is introduced by `bridge`,
through:

- source-only modules;
- exact DSO;
- exact regular archive;
- ancestor multi-module DSO;
- ancestor multi-module archive;
- dynamic preference;
- `--static` preference; and
- standalone linking.

Assert the selected physical provider remains transient and Interface metadata
does not import every other key from a container.

### 7.5 ABI, installer, and standard-library tests

Update:

- `spec/abi_spec.lua`;
- active-path and suffix assertions throughout driver/coder tests;
- `spec/libuv_build_spec.lua`;
- `spec/rockspec_spec.lua`;
- `spec/stdlib_installer_spec.lua`;
- `spec/installed_prefix_spec.lua`;
- `spec/stdlib/fs_spec.lua`;
- `spec/stdlib/uv_late_callbacks_spec.lua`;
- `spec/support/make_delayed_fs_callback_variant.lua`;
- `spec/support/uv_late_fs_callback_cases.lua`;
- `spec/stdlib/timer_spec.lua`;
- `spec/stdlib/net_spec.lua`;
- `spec/stdlib/os_process_spec.lua`;
- OS/net production smoke fixtures;
- `spec/support/ci_libuv_mode_smoke.sh`; and
- snapshot/sanitizer support where exact active paths/counts appear.

FS behavior coverage:

- omitted and explicit-nil default size;
- explicit valid/zero/negative/over-limit size;
- no result larger than requested, including excess;
- delimiter within one chunk and across native reads;
- binary NUL delimiter/data;
- include/chop and delimiter-at-start;
- empty delimiter;
- retained overread consumed by plain/read-until calls;
- retained excess shorter than `max` returns immediately without a native
  top-up, while excess longer than `max` is sliced and retained;
- many-chunk read-until accumulation without quadratic prefix rebuilding and
  with checked total-length overflow behavior;
- EOF empty and unterminated tail;
- later growth after EOF;
- cancellation and error restoration;
- FIFO proof that write/flush/close cannot interleave between one logical
  read-until's submissions;
- concurrent reader rule; and
- calls through `ReaderWriterCloser` exercising both adapters.

Normal `fs_spec` covers public behavior, but post-consumption
cancellation/error restoration needs the isolated delayed-FS flow. Extend
`make_delayed_fs_callback_variant.lua` with uniquely anchored Nth-read
delay/failure behavior and add cases in `uv_late_fs_callback_cases.lua` proving
that accumulated and excess bytes are restored in order and remain readable.
Run them through `uv_late_callbacks_spec.lua`; keep all hooks out of installed
modules and preserve the validated `TITAN_TEST_UV_LATE_FS_ONLY=1` sanitizer
scope.

OS coverage:

- `spawn` initializes public stdin/stdout/stderr records;
- stdin exact `WriterCloser`;
- each output exact `Reader`;
- stdout/stderr independent retained state and reader locks;
- full migration from old forwarding calls;
- stdin close/write FIFO and idempotence;
- terminal tails, sticky read errors, cancellation, wait/kill/lifecycle;
- interface wrapper retaining a pipe/native owner after Process source
  reference is dropped; and
- public pipe-field reassignment behaves as ordinary mutable record fields.

Net coverage:

- all seven structural matches;
- exact composite dispatch;
- named `read_until`;
- bound method;
- incidental `Server:close` implementation; and
- no behavioral regression to stream state.

Timer coverage in `spec/stdlib/timer_spec.lua` casts `timer.Ticker` to
`io.Closer`, dispatches `close`, and proves the existing close/wait semantics
and ownership cleanup are unchanged.

Packaging/installer coverage:

- exact ten roots/modules/keys/shims;
- exact eleven DSO openers;
- `titan.io` metadata protocol;
- bundled and system libuv modes;
- DSO/archive/types equality;
- fresh-process archive validation;
- bootstrap, active legacy-without-archive, and complete predecessor;
- archive and DSO failpoint rollback restoring all ten shims;
- dSYM behavior;
- source-rock contents;
- an exact fixture assertion that actually consumes the new `titan.io` entry
  in `spec/fixtures/stdlib/titan_stdlib_types.lua` (rename/extend the current
  seven-root `PREEXISTING_STDLIB_ROOTS` loop or add a dedicated assertion);
- `luarocks test` discovery; and
- builtin Lua `io` coexistence.

## 8. Diagnostics

Prefer stable, source-level messages. At minimum define/test:

- `interface 'I' must declare at least one method`;
- `redeclaration of method 'm' in interface 'I'`;
- `interfaces cannot be local`;
- `interface methods cannot be local`;
- `record 'R' does not implement interface 'I': method 'm' is missing`;
- `... method 'm' is local to module 'x'`;
- `... method 'm' has incompatible type 'found'; expected 'expected'`;
- `interface 'I' is a type and has no runtime value`;
- `cannot convert value holding '<actual>' to interface 'I'; an existing I
  wrapper is required`;
- `cannot cast interface 'I' to record/union 'R'` at runtime;
- `method 'm' not found in interface 'I'`;
- wrong Lua receiver for `I:m`;
- attempted Interface field assignment; and
- malformed provider Interface schema with the candidate path/name retained.

Use existing type/location formatting. Do not expose private slot numbers,
payload offsets, raw mangled symbols, or unordered Lua table iteration.

## 9. Phased implementation and review sequence

### Phase 0 — decisions, reading, baseline, and architecture proofs

1. Record maintainer answers to every item in §0 at the top of this plan and
   revise normative sections before coding.
2. Assign compiler/runtime agents only after they complete §4.1's
   implementation-manual reading.
3. Establish a clean baseline with targeted existing tests and `make test` in
   an isolated prefix; record any pre-existing failure.
4. Complete and accept the separate
   `.agents/plans/type-relations-soundness.md` remediation before changing the
   central relations for Interface. Interface work must consume its regression
   tests and invariants.
5. Prototype the common function-pointer copied-array representation under the
   supported C toolchains/warnings.
6. Prototype concrete-owner adjustment lowering for every §0.2 case, two Lua
   states, and dynamic/static providers.
7. Characterize current top-level bound method/lambda tag initialization with
   a focused regression.
8. Decide trace attribution from the prototype output.

**Gate:** the central relation/Array/function remediation is implemented and
its relation, dynamic-boundary, strict-read, callable, and ABI regressions are
green; every adapter proof passes the concrete-owner `_mod` supplied by
wrapper uservalue 0 without a caller/casting-module identity, third context
object, or per-state static pointer.

### Phase 1 — syntax, descriptors, checker, and draft language manual

1. Implement keyword, AST, parser, errors, and `io` import alias.
2. Implement Interface/Method descriptor projection, the ordered direct
   satisfaction matcher, source-to-target coercion plan, and non-recursive
   pair annotations.
3. Add declaration staging, type-only publication, qualified type
   resolution, export validation, calls/references, casts/options/downcasts,
   and deterministic diagnostics.
4. Add lexer/parser/types/checker suites.
5. Draft/link `doc/language/interfaces.md` and update the core language
   chapters.
6. Run a compiler-semantics review by an agent that has read the relevant
   implementation chapters.

**Gate:** no coder stubs may silently accept an undecorated Interface cast.
Checker tests must prove every representation-changing sink carries one
ordered mapping, while audited representation-preserving
Array/Map/function consistency continues through its ordinary checked
boundary and never lifts the Interface coercion.

### Phase 2 — exact runtime representation, Lua dispatch, and bound methods

1. Add runtime storage typedef/helpers and Interface metatable ownership.
2. Add wrapper construction, exact pair slots, direct calls, `value`,
   downcasts, equality, and GC.
3. Parameterize Lua-entry generation for payload dispatch.
4. Add bound native/coercive-Lua/strict-Titan trampolines and cross-module
   symbol recovery; store the fixed brand before the captured wrapper and
   append the strict LCF after it.
5. Move function-tag initialization before module variables and add the
   existing-feature regression.
6. Add exact coder/Lua/bound/GC/backtrace tests.
7. Draft corresponding sections of `doc/implementation/interfaces.md`.
8. Run a runtime/GC adversarial review.

**Gate:** exact Titan/interface/bound calls use native paths, non-exact bound
calls use the strict trailer, genuine Lua calls alone use the coercive entry,
two Lua states work, and wrapper/module/self lifetime is proven under both GC
modes.

### Phase 3 — adjustment wrappers and separate compilation

1. Turn the Phase-0 adapter prototype into checker-elaborated constrained
   synthetic IR.
2. Add deterministic annotated-pair collection, wrappers, vtable init order,
   and adapter trace names.
3. Cover the full adjustment matrix.
4. Add source/DSO/archive/prefix/standalone four-module proofs.
5. Extend loader symbols, collisions, static wiring, the explicit
   no-Interface public-prefix case, and hostile schema validation.
6. Complete `doc/implementation/interfaces.md` and provider sections.
7. Run independent type-soundness and generated-C reviews; both reviewers must
   read the relevant implementation chapters first.

**Gate:** every adapter interprets `_mod` as the concrete owner's module
layout, independent of its emitting TU; all providers agree on ordered
metadata and callable ABI.

### Phase 4 — complete ABI 0.20, manuals, packaging, and clean-prefix proof

1. Inherit the relation PR's single mechanical 0.19-to-0.20 marker/path
   advance; complete and verify every active ABI reference and add the runtime
   history paragraph without a second version transition.
2. Extend the closed DSO/archive validator and ABI rejection tests.
3. Update all current manuals, README, repository instructions, workflows,
   support scripts, and active-prefix checks without rewriting history.
4. Prepare a fresh isolated ABI-0.20 prefix and prove 0.19 providers fail before
   Interface rehydration.
5. Review loader/static/provider/installer changes adversarially.

**Gate:** source, DSO, archive, prefix-container, and standalone modes are
green on a clean 0.20 tree before stdlib publication expands.

### Phase 5 — language-doc-gated stdlib dogfood

1. First make a documentation/spec pass: draft
   `doc/language/standard-library-io.md` and the intended fs/os API updates
   against the already reviewed `doc/language/interfaces.md`.
2. Before any Titan stdlib implementation, every dogfood implementation/review
   agent reads the updated language documents and the phase-relevant
   implementation chapters listed in §4.1, including the new Interface and IO
   chapters.
3. Add `titan.io`.
4. Implement queued low-level fs read/read-until state and facade API.
5. Refactor OS process pipes and migrate every caller/spec/smoke.
6. Add exact/adjusted interface use to net/fs/os behavior and production
   smokes.
7. Expand Make/installer/provider/fixtures from nine to ten logical modules.
8. Finish the fs/net/os/async/IO manuals against tested behavior.
9. Run separate fs FIFO/cancellation, OS ownership/lifecycle, and
   packaging/rollback reviews.

**Gate:** behavior suites remain outside coverage; installed DSO and archive
smokes prove the dogfood interfaces, exact ten-key metadata, ten shims, and
eleven openers.

### Phase 6 — whole-tree validation and publication

1. Run formatter/style/diff checks and all targeted suites.
2. Run full `make test` from repository root on a current isolated install.
3. Run the same compiler/language and library grouping used by Linux CI.
4. Assign final adversarial reviewers for:
   - language semantics/type soundness;
   - runtime ABI/GC/generated C;
   - source/DSO/archive/installer/rollback;
   - fs/net/os behavior; and
   - both manuals/repository instructions.
5. Resolve findings and rerun affected targeted/full gates.
6. Commit intentionally on a feature branch, push, and verify exact-head Linux
   CI plus Codecov uploads.
7. Only after final Linux and adversarial review are green, manually dispatch
   one exact-head macOS `workflow_dispatch` pre-merge run. If that run requires
   a patch, re-establish exact-head Linux and run the necessary final macOS
   check; do not call a stale run the gate.
8. Refresh the PR description with semantics, ABI break, dogfood migration,
   decisions, tests, and CI evidence.

## 10. Verification commands

Use a unique absolute isolated prefix per worker. From repository root:

```sh
export PREFIX="/tmp/titan-$USER-interfaces-main"
export PATH="$PREFIX/bin:$PATH"

make lua
make luarocks
make lpeglabel
make libuv
"$PREFIX/bin/luarocks" make
```

Frontend/type/checker:

```sh
busted spec/lexer_spec.lua
busted spec/parser_spec.lua
busted spec/types_spec.lua
busted spec/checker/interfaces_spec.lua
busted spec/union_interface_spec.lua
```

Coder/provider:

```sh
busted spec/coder/interfaces_spec.lua
busted spec/coder/bound_methods_spec.lua
busted spec/coder/closures_spec.lua
busted spec/coder/backtrace_spec.lua
busted spec/checker/so_rehydration_spec.lua
busted spec/coder/so_import_spec.lua
busted spec/checker/static_compiled_modules_spec.lua
busted spec/coder/static_compiled_modules_spec.lua
busted spec/coder/multi_module_libraries_spec.lua
busted spec/driver_spec.lua
busted spec/staticmetadata_spec.lua
busted spec/abi_spec.lua
```

Dogfood/packaging:

```sh
busted spec/stdlib/fs_spec.lua
TITAN_TEST_UV_LATE_FS_ONLY=1 busted spec/stdlib/uv_late_callbacks_spec.lua
busted spec/stdlib/timer_spec.lua
busted spec/stdlib/net_spec.lua
busted spec/stdlib/os_process_spec.lua
busted spec/libuv_build_spec.lua
busted spec/rockspec_spec.lua
busted spec/stdlib_installer_spec.lua
bash spec/support/ci_libuv_mode_smoke.sh
```

Whole tree:

```sh
make test
bash spec/support/ci_test_groups.sh compiler
bash spec/support/ci_test_groups.sh libraries
git diff --check
```

Use the workflow's documented environment for the mode smoke if it requires
explicit bundled/system variables; do not copy an obsolete command from this
plan over the current script contract.

Publication evidence:

```sh
gh run list --branch <feature-branch>
gh workflow run ci.yml --ref <feature-branch>
gh run view <run-id>
```

The manual dispatch is the macOS gate only; Linux evidence comes from the
final pushed head.

## 11. Completion criteria

The feature is done only when all of these are true:

- every §0 decision is resolved and reflected consistently in spec, code,
  tests, and manuals;
- compiler and review agents completed the relevant implementation-manual
  reading gate;
- dogfood implementation/review agents read the language manual including the
  new Interface and IO chapters plus their relevant implementation chapters;
- Interface syntax, nominal identity, direct structural satisfaction, named
  calls,
  options, `value`, downcasts, and equality match §2;
- every representation-changing scalar use has an explicit checked cast;
- the completed central relation-remediation suite proves every
  consistency/coercion/dynamic/open-run caller either preserves
  representation or emits the required conversion;
- concrete-to-Interface satisfaction is used only to build one direct outer
  coercion plan; no subtype relation, transitive implementation closure, or
  Array/Map/Function lifting exists;
- exact and adjusted native paths both work, including variadic/flexible
  adjustment;
- adjustment wrappers use the accepted module-context design and no wrong
  private slot identity;
- wrappers have exactly two traced uservalues and a copied ordered vtable;
- exact bound method values retain the native fast path, including top-level
  initializers;
- non-exact bound method values use the strict trailing entry while preserving
  the captured Interface wrapper at upvalue 4;
- bound Interface closures carry the same fixed ABI brand at upvalue 3 across
  source, DSO, and archive providers;
- written `value as/is I`, Lua function formals, record/module writes, Array
  writers, and non-Titan Lua callable results consume the same
  `DynamicCoercionPlan(I)`, accepting an existing exact wrapper (or nil for
  `I?`) and rejecting a bare implementing record/union;
- every typed Interface Map read is strict and origin-independent, including
  after raw Lua mutation;
- Lua dispatch, protected metatables, readonly surface, and builtin `io`
  coexistence are proven;
- GC/failure/backtrace tests cover module, self, wrapper, and adapter frames;
- hostile Interface schemas fail in the existing module-interface validation
  suite;
- the consumer-knows-only-I topology passes source, DSO, archive, prefix, and
  standalone modes;
- ABI 0.20 contains the inherited single marker/path advance, every Interface
  addition, and clean rejection of 0.19 without another version transition;
- the Interface chapters in both manuals and
  `doc/language/standard-library-io.md` are linked, and all affected current
  documentation is accurate;
- `titan.io` publishes seven interfaces;
- fs read/read-until preserves one logical FIFO operation and all documented
  cancellation/error/excess behavior;
- Process pipe records preserve lifecycle semantics and the old forwarding
  surface is fully migrated;
- the standard provider has exactly ten modules/keys/shims and eleven openers,
  with rollback proofs;
- targeted suites and `make test` pass;
- final adversarial reviews are resolved;
- exact-head Linux CI and Codecov uploads are green; and
- one final exact-head macOS manual pre-merge run is green.

## 12. Principal risks and review traps

1. **Wrong module identity in adapters.** Every entry receives the concrete
   owner's `_mod`; interpreting it as the emitter/caller/casting module corrupts
   private slot identity.
2. **Relation/caller contract drift.** A caller that treats gradual
   consistency as permission to emit a representation-changing `ExpCast`,
   or treats a real coercion as a no-op, can crash code generation or pass the
   wrong representation. The separate relation audit/remediation is a
   prerequisite.
3. **Matcher scope creep/order.** Reusing structural satisfaction in method
   components or compound relations would recreate subtyping/coercion
   lifting; unordered maps can still make metadata/vtables disagree.
4. **Initialization order.** Imported symbols, metatables, function tags, and
   pair vtables must exist before module initializers allocate wrappers or
   bound closures.
5. **Bound ABI confusion.** Raw vtable entries take explicit `self`; bound
   function fast paths require a separate trampoline.
6. **GC during half construction.** Both wrapper and concrete receiver must be
   rooted before any allocating conversion; both uservalue stores need
   barriers.
7. **Type-namespace confusion.** Interface is a nominal direct `type_members`
   declaration, not a transparent alias and not a runtime `members` slot.
8. **Synthetic traceback leakage.** Private adapter symbols need stable
   attribution without pretending they are public declarations.
9. **ABI partial bump.** One stale `_0_19`, `TITAN_PATH_0_19`, active path, or
   fixture can create misleading loader behavior.
10. **Provider symbol asymmetry.** Bound trampolines must be equally reachable
    in source, DSO, archive, ancestor-container, and standalone modes.
11. **FS facade loop.** Repeating public `_fs_read` operations violates the
    documented per-file FIFO by permitting interleaving.
12. **OS ownership cycles/regressions.** Pipe records must retain the native
    handle without weakening close/read/wait cleanup.
13. **Count drift.** Ten logical modules means ten keys and shims but eleven
    openers; installer snapshots and docs often encode these separately.
14. **Coverage misclassification.** Library behavior belongs outside LuaCov;
    compiler gaps need focused compiler tests.
15. **Documentation ordering.** Dogfood agents must implement against the
    reviewed new language contract, not infer semantics from compiler code.
16. **Calling the coercive entry from Titan.** A non-exact bound Interface
    method must use the shared strict function trailer; routing it through the
    Lua trampoline would reintroduce coercions inside gradual consistency.
17. **Dynamic implementation discovery.** Knowing target `I` does not authorize
    written `value as I` or a Lua sink to wrap a bare record/union. Only a
    statically planned Titan `R/U -> I` coercion constructs the wrapper.
18. **Strict-trailer symbol asymmetry.** Cross-module bound Interface methods
    need the strict entry wherever the existing native and Lua trampolines are
    exported/recovered.
19. **Dynamic-plan drift.** Written `value as/is I`, Lua function arguments,
    record/module writes, Array writers, and non-Titan Lua callable results
    must lower the same exact-wrapper-only `DynamicCoercionPlan(I)`.
20. **Map provenance exceptions.** Raw Lua Map mutation performs no Interface
    coercion; a later typed read is strict regardless of where the payload
    originated.

If any solution begins to require hidden link identities, symlinks/hard links,
an untracked context object, repeated special-case relations, or a growing
set of per-feature loader exceptions, pause and ask the maintainer. That is a
signal that the intended invariant has been misunderstood, not a reason to add
another workaround.
