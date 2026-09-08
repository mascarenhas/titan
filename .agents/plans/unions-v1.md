# Unions v1 — expanded specification and implementation plan

Status: **implementation and local validation complete; publication and
exact-head Linux CI are in progress**.

Primary feature brief:
`/home/mascarenhas/.codex/attachments/6415aa55-f007-4c82-8ab6-f2562946a400/pasted-text-1.txt`

This plan expands that brief against the current compiler, manuals, standard
library, module-interface format, installer, and CI layout. It preserves the
intended small nominal-sum feature, reuses record/static/method machinery where
the representations genuinely coincide, and calls out the places where doing
so would otherwise hide a language-design decision.

## 0. Owner decisions recorded

The owner has resolved every design question raised by the first plan review.
These decisions are normative for the rest of the plan.

### 0.1 Every case arm uses `when`

`when` is clearer and more future-proof than overloading `if`, `elseif`, or
`of`, so every arm uses the same spelling:

```titan
case msg
when move: d then
    process_move(d.x, d.y)
when write: s then
    write_output(s)
else
    quit()
end
```

This avoids the committed-choice ambiguity between a following arm and an
ordinary `if` statement inside the preceding full block. `union`, `case`, and
`when` all become Titan keywords.

`when` is not reserved by C. Titan already preserves keyword spellings for C
parameter labels through contextual `NAMEDLABEL`; v1 generalizes that
convention into a metadata-backed contextual FFI selector/type rule. A header
declaration, field, parameter, or other exposed C symbol spelled `when` must
remain usable wherever that class of FFI symbol is source-nameable. The same
general rule fixes older Titan-only C identifier spellings such as `repeat` or
`type`; it does not make any keyword legal in ordinary Titan identifier
positions.

### 0.2 Corrected examples and positional constructors

The brief's `require` and `number` spellings were oversights: Titan source uses
`import` and the intended numeric type is `float`. Bare-call record syntax is
still reserved for named calls, so a record payload is parenthesized:

```titan
record Delta
    x: float
    y: float
end

union Message
    quit
    move: Delta
    write: string
end

local a = Message.quit()
local b = Message.move({ x = 1.0, y = 2.0 })
local c = Message.write("hello")
```

The corrected imported form is also part of the normative example and test
contract:

```titan
-- messages.titan
record Delta
    x: float
    y: float
end

union Message
    move: Delta
end

-- consumer.titan
local m = import "messages"
local moved = m.Message.move({ x = 1.0, y = 2.0 })
```

The parenthesized initializer is one positional expression contextually typed
as `Delta`. Union constructors are intentionally positional-only in v1.
Synthesized payload constructors therefore publish `paramnames = false`;
their positional calls still nil-fill missing arguments, evaluate and discard
surplus arguments, and remain first-class.

“A bare variant name as a value” means a selector on its union namespace:
`Message.move` or `m.Message.move`. An unqualified `move` is ambiguous because
different unions may use the same variant name.

### 0.3 Imported unions follow current record visibility

Imported union types follow the current declaration-frontier behavior for
records exactly:

- a union declared in the current module is visible throughout that module;
- an imported union is qualified by its import alias;
- alias targets, record fields, union payloads, callable signatures, and
  ordinary function/method/static/module-initializer bodies may directly use an
  imported union even when the import appears later in combined AST order;
- a module-variable annotation or initializer may directly use a qualified
  imported union only when that import is earlier, and a lambda nested in the
  initializer retains the same earlier-import/module-variable frontier; and
- because aliases and their targets are module-wide, an earlier module variable
  may still use an alias whose target names a later imported union. Only the
  direct qualified spelling is hidden at that frontier.

There is no union-specific forward-only scope rule.

### 0.4 Clean ABI boundary

The feature advances the ABI because it changes serialized union schemas and
module layout. There is no in-place migration promise. Development and CI use
a fresh prefix, and focused synthetic mismatch tests prove incompatible
providers fail before their type metadata is decoded.

Linux preparation creates `$PREFIX/bin/lua`, runs `make lua` and `make
luarocks`, configures Lua's compiled `package.cpath`, and clears only known
Titan-owned active-install state before `luarocks make`. Native dependency
caches remain keyed by `TITAN_ABI_VERSION`; install/search paths use
`TITAN_LIBRARY_VERSION`. Do not add a multi-version build path.

### 0.5 Settled v1 edge semantics

- A union must declare at least one variant. Empty/uninhabited unions are
  outside v1.
- A payload variant may be tested without a binding. An empty variant may not
  have a binding because it has no payload type and allocates no payload user
  value.
- Repeating a variant arm in one `case` is a compile-time error.
- A `case` scrutinee of type `Union?` is implicitly unwrapped to `Union` through
  Titan's existing option-force cast. A present value dispatches normally; nil
  raises the ordinary run-time “expected Union but found nil” type error before
  any arm runs. Other non-union types, including `value`, remain errors.
- Cases need not be exhaustive. If no arm matches and there is no `else`, the
  statement does nothing and execution continues.
- The always-return result uses the closed union: every explicit arm must
  terminate, and either the unique arms cover all `nvariants` or an explicit
  `else` must terminate. Complete coverage makes a redundant `else`
  unreachable, so its fallthrough does not defeat the proof. Imported hidden
  variants remain in `nvariants`, preventing visible arms alone from proving
  complete coverage.
- Union payloads and record fields have the same userdata-user-value storage
  contract. Both must use one shared `types.has_tvalue_representation`
  eligibility check: direct C aggregates, C arrays, direct C functions, and C
  function pointers are rejected; ordinary Titan values and the same boxable
  C scalars, object pointers, `TValue`, `Udata *`, and owned values accepted in
  record fields remain legal.
- Applying that existing user-value predicate to record fields makes their
  frontend rule explicit and intentionally tightens the currently unchecked C
  array/function-pointer cases; audit existing sources and fixtures and
  document that compatibility change rather than describing it as only a new
  union restriction.
- Titan unions use the same explicit nominal GC-identity cast to C `void *` and
  ordinary `value` boxing as records. They are not C unions, just as Titan
  records are not C structs; no structural aggregate cast is added.

### 0.6 Variants are metadata and constructors, not types

Variants are not first-class types in v1. The internal `Type.Variant`
descriptor is declaration/interface metadata for a tag, optional payload, and
constructor; it is never the static type of a value and is never a
source-resolvable type target.

Consequently:

- annotations, aliases, parameters, results, payloads, and container elements
  may name the union, never one of its variants;
- `x as Message.move` and `x is Message.move` are rejected cleanly;
- `x as Message` and `x is Message` retain the ordinary nominal cast/type-test
  behavior; and
- `case` is the v1 operation for testing a value's variant and optionally
  binding its payload.

## 1. Outcome, scope, and non-goals

This feature delivers:

- top-level nominal union declarations with empty or single-payload variants;
- union-local and variant-local visibility;
- one ordinary static constructor per variant;
- union static functions, methods, first-class constructors, and bound methods;
- a statement-form `case` whose arms each begin with `when`, with optional
  payload bindings and `else`;
- ordinary option auto-unwrapping when a `Union?` is scrutinized;
- immutable tag/payload selection with reference-preserving payload copies;
- a `Udata *` representation with a metatable type tag and ordinary typed user
  values;
- source, DSO, and static-archive module-interface support;
- Lua-facing constructor/static/method support without exposing tag/payload;
- the compiled-module ABI boundary and independently release-versioned
  installation/search paths;
- a new language chapter and implementation chapter, integrated into both
  manuals; and
- conversion of the private regular-expression AST from integer-kind records
  to a real local union after the core feature is green.

It replaces the README roadmap item for “tagged variants.”

This iteration does **not** add:

- anonymous/in-line record payload syntax in union declarations;
- variants with multiple independent payload parameters;
- a pattern expression, a value-producing `case`, guards, nested patterns, or
  record/array destructuring;
- exhaustiveness checking, unreachable-arm warnings, or flow-sensitive
  narrowing;
- a public tag accessor, payload accessor, reflective variant names, or tag
  mutation;
- a first-class variant/refinement type usable in annotations, aliases,
  `as`, or `is`;
- structural compatibility between different unions;
- implicit conversion from a payload type to its union;
- derived equality/order/hash behavior; union equality is object identity like
  records;
- inheritance, interfaces, generic unions, or open/extensible unions;
- C `union` interoperation beyond the already-supported nominal identity cast;
- a generalized “enum” integer representation;
- an installation migration across the ABI boundary; or
- changes to the static metadata container format. Its embedded Titan
  interface gains new type constructors, but the existing ABI gate remains the
  discriminator.

Debug-library or C-API mutation of private userdata user values opts out of
Titan's safety contract, as it does for record and Array internals.

## 2. Normative language specification

### 2.1 Lexical and declaration syntax

`union`, `case`, and `when` become reserved words. Longer identifiers such as
`unionized`, `casefold`, and `whenever` remain ordinary names. Existing Titan
source must not use any exact new keyword as an ordinary identifier after this
ABI boundary. The contextual FFI-symbol path remains able to represent C identifiers
spelled `when`, because C does not reserve it.

With the arm decision in §0.1, the grammar is:

```text
union-declaration ::= ["local"] "union" Name union-variant+ "end"
union-variant     ::= ["local"] Name [":" type] [";"]

case-statement    ::= "case" expression
                    ("when" Name [":" Name] "then" block)+
                    ["else" block]
                    "end"
```

A union declaration is legal only among a module's top-level declarations. It
is not an expression and cannot be nested in a function, block, record, or
other union. Optional semicolons follow the existing record-field convention.

Variant names are ordinary identifiers. Each union has at least one variant.
The payload annotation is absent for an empty variant and contains exactly one
type otherwise. The payload type may name the union itself, a later nominal
declaration, or another recursively connected nominal type because nominal
declarations are collected module-wide.

### 2.2 Nominal identity and compatibility

The type of a union value is the fully qualified declaration identity
`module.UnionName`. It is represented in checked expressions by
`Type.Nominal(fqtn)`, exactly as a record value is.

- A union is compatible with itself.
- Different union declarations are incompatible even when their variants are
  textually identical.
- A union and a record are incompatible.
- A union is compatible with `value` in both directions through Titan's
  gradual boundary.
- `Union?` is the ordinary option of that nominal type.
- Arrays, Maps, functions, options, and aliases containing a union follow
  their existing recursive rules; compatibility never compares a union's
  variant structure.
- `==`/`~=` compare union userdata identity. Two separately constructed
  values with the same variant/payload are still distinct objects.

The normal explicit cast/type-test machinery applies. In particular, a
`value` may be checked/cast to a union by its metatable identity, and a union
may use the same explicit nominal-identity-to-C-`void *` cast available to
records. There is no structural C-union conversion. A variant descriptor is
not a type: `Message.move` remains a constructor value selector and is rejected
as the right-hand side of `as` or `is`; use the union type `Message` for a
nominal cast/test and `case` for a variant test.

### 2.3 Variants and constructors

Variant names are unique within one union. Two separate unions may reuse the
same names and payload types. Multiple variants in one union may be empty or
have the same payload type.

Each variant synthesizes a static function in its union namespace:

```text
empty variant       () -> Union
payload variant     (Payload) -> Union
```

Thus:

```titan
Message.quit()
Message.move({ x = 1.0, y = 2.0 })
Message.write("hello")
```

The selector itself is a first-class constructor value:

```titan
local make_write: (string) -> Message = Message.write
local msg = make_write("hello")
```

An imported selector is qualified through both namespaces:
`m.Message.write`.

The internal variant descriptor does not create a variant value type.
Annotations, aliases, casts, tests, and other type positions can name
`Message`, but not `Message.write`; the latter spelling selects the
first-class constructor only in an expression namespace.

A transparent type alias may name the union in annotations, casts, payloads,
and `case` scrutinees:

```titan
type Event = Message
local current: Event = Message.quit()
```

As with a record alias, `Event` remains type-only and is not a runtime
namespace. `Event.quit()` and `Event.write` are errors; construction and
first-class selection use the owning `Message` namespace (or the imported
owner path).

Constructor calls are ordinary fixed Titan calls:

- all argument expressions are evaluated left to right;
- surplus arguments are evaluated and discarded;
- an omitted payload is a synthesized nil and is accepted only when nil can
  adjust/coerce to the payload type; and
- a first-class constructor has the same adjustment and exact/generic callable
  paths as any function value.

As with `Rec.new`, a direct or imported synthesized union-constructor call is a
legal module-variable constant expression when every adjusted argument
expression is constant. A nonconstant argument remains illegal there. A
user-written static is not a constructor merely because it returns its owning
union and is not thereby admitted as a module constant.

Constructors do not publish named-argument metadata because the variant
declaration has no payload parameter label. `Message.write { ... }` is
therefore rejected as an unavailable named call; use parentheses.

The selected variant and stored payload cannot be replaced after construction.
“Immutable payload” refers to that union slot. Copying a reference payload out
of a case does not deep-copy the referenced object: mutating an Array, Map,
record, owned object, or other mutable referenced value through the binding is
visible to all aliases.

### 2.4 Static functions, methods, and one member namespace

Unions accept the existing record member declarations:

```titan
[local] function UnionName.function_name(params): returns
    body
end

[local] function UnionName:method_name(params): returns
    body
end
```

A method has an implicit `self` of the union's nominal type. Direct method
calls, optional receiver behavior, method locality, and `value:method` generic
boundaries follow records. `exp:method` without arguments creates the same
kind of bound method closure, capturing the union userdata as `self`.

Variants, user-written statics, and methods share one name set:

- no two variants in a union have the same name;
- a user static cannot use a variant or method name;
- a method cannot use a variant or static name; and
- duplicate statics/methods retain the existing first-declaration diagnostics.

Unlike a record, a union has no fields. `u.name` never exposes a variant,
payload, or method to Titan expression syntax; variants/statics are selected
from the type namespace (`UnionName.name`), and methods use `u:name`.

### 2.5 Visibility and module interfaces

A `local union` is visible only inside its defining logical module. It is
omitted from the module interface and cannot escape directly or through:

- exported variables or functions;
- public records, unions, variants, statics, or methods;
- public aliases;
- option/container/function types; or
- a transitive re-export.

A public union may contain a `local` variant. That variant:

- remains usable throughout the defining module;
- has a local constructor;
- is omitted from source-import and compiled-module public interfaces;
- cannot be named in a case outside the owner module; and
- remains safely catchable by an external `else`.

The hidden variant's payload type is also omitted. It may therefore name a
local nominal or a module-local, boxable C FFI type. A public variant's payload
is part of the exported interface and may not expose a local nominal or any C
FFI type, under the existing export rules.

A local union makes every constructor/namespace operation effectively private
even when its variants are not individually marked `local`.

Imported public unions are selected as `alias.UnionName`; their variants and
statics are `alias.UnionName.member`. Their declaration frontier follows
§0.3.

### 2.6 Case statement

The scrutinee:

- is evaluated exactly once, in scalar context;
- is passed through the existing `tryforce` option-unwrapping path, so a
  `Union?` becomes the exact union or raises the ordinary type error on nil;
- after that force, must have an exact `Type.Nominal` whose registered
  declaration is a visible `Type.Union`;
- may belong to any visible exact union; and
- receives no coercion from `value` or a record, or from one union to another,
  merely to make a case applicable.

Each arm name is resolved only within the scrutinee's union. It is not an
ordinary variable lookup and is not qualified. An arm must name a visible
variant and may appear only once in that case.

The body after each `then`, and the optional `else` body, is Titan's full
regular `block` production—not a `simpleblock` or a bare statement list.
This is deliberately identical to an `if`/`elseif`/`else` branch block: case
introduces no new handler, cleanup, or fallthrough semantics.
Consequently every individual arm may carry its own `catch`, `finally`, or
`catch` followed by `finally` trailers:

```titan
case msg
when write: text then
    consume(text)
catch
    log_failure(error, traceback)
finally
    release_output()
when quit then
    stop()
end
```

Those trailers belong only to the arm immediately before them, exactly as for
an ordinary conditional branch. Their protected body, catch, and finally reuse
the existing sibling-scope, implicit-catch-local, always-termination,
pending-return/break, and finally-transfer rules. A handler on one arm never
protects another arm or the scrutinee evaluation; the `else` arm has the same
trailer capability.

The existing parser `defer` transformation applies independently to the
protected body, catch, and finally simpleblocks inside each full arm block. A
defer tail ends at that clause/arm's real delimiter and never absorbs a later
`catch`, `finally`, `when`, `else`, or sibling arm.

For a payload variant:

```titan
case msg
when write: text then
    consume(text)
else
end
```

`text` is a new ordinary mutable local whose static type is the variant's
payload type. Its scope is exactly that arm. The payload user-value slot is
read into the local through the same representation-specific `getslot` path as
a record field:

- primitives and direct `TValue`-represented values are copied;
- an Array remains its internal backing `Table *`; no Lua-facing proxy is
  introduced merely because it is stored in a user value;
- strings, Arrays, Maps, records, unions, functions, and owned values retain
  their normal shared identities; and
- assigning a new value to `text` changes only the local, never `msg`.

The binding may be omitted to test only the tag. Adding a binding to an empty
variant is a compile-time error. Each arm and the `else` has its own lexical
scope. A binding is an arm-local established before the full block, so it is
visible in that arm's protected body and its sibling catch/finally clauses;
locals declared inside the protected body retain the ordinary rule that they
are not visible in catch/finally. The binding can be captured by a lambda under
the existing capture/box rules and cannot be referenced from another arm or
after the case.

Arms are tested by tag, not in source-order comparison code. Exactly one
selected arm executes. There is no fallthrough.

Exhaustiveness is not required in v1:

- `else` handles every unlisted tag, including a local variant hidden from an
  importer;
- without `else`, an unmatched valid variant jumps to the end; and
- no warnings are emitted for omitted or unreachable coverage beyond the
  duplicate-arm error.

For the checker's existing always-return analysis, a `case` returns on every
path when every explicit arm is terminating and either those unique arms cover
all variants of the statically known closed union or an explicit `else` is
terminating. A redundant fallthrough `else` is unreachable after complete
coverage. Listing every visible variant of an imported public union is not
enough when its preserved `nvariants` count includes hidden variants.

`return`, `raise`, `defer`, `catch`, `finally`, and a `break` targeting an
enclosing loop retain their ordinary meanings inside an arm, including
inside-out defer/finally cleanup and the normal ban on transfers that escape a
finally.

### 2.7 Lua-facing behavior

For an exported union in module `m`:

- `m.UnionName` is the same kind of namespace table records use, exposed as a
  read-only member of `m` and initially populated with constructors/public
  statics (the module member cannot be rebound; the table itself retains the
  existing record-namespace Lua behavior);
- `m.UnionName.variant(...)` invokes the generated Lua entry for that
  constructor;
- public methods are returned by userdata `__index` and work with Lua's
  `u:method(...)` syntax;
- local variants/statics/methods are absent;
- the tag and payload are never fields and cannot be read or assigned;
- every `__newindex` attempt raises;
- `getmetatable(u)` returns a protected name such as
  `"Titan union module.UnionName"`; and
- passing the wrong nominal userdata into Titan raises the existing
  metatable-based type error naming expected and found types.

The same userdata object crosses Titan/Lua/value boundaries, so equality and
reference-payload aliasing remain stable. Lua does not gain a `case` operation
or reflective tag API in v1.

## 3. Runtime and ABI contract

### 3.1 In-memory representation

Every union value is a Lua 5.5 full `Udata *` with the union's unique metatable:

```text
Udata
  metatable -> canonical "Titan union <fqtn> metatable"
  uv[0]     -> integer, absolute 0-based variant tag
  uv[1]     -> typed internal payload slot, only for a payload variant
```

- An empty-variant instance is allocated with `nuvalue == 1`.
- A payload-variant instance is allocated with `nuvalue == 2`, even when the
  payload's value is nil.
- Tags use complete source declaration order. Local variants consume indices.
- Different instances of one union may therefore have different `nuvalue`.
- Recursive union payloads are just `Udata *` values in `uv[1]`; there is no
  recursive C layout.

The metatable pointer is nominal identity. Record and union metatable registry
keys are distinct (`Titan record ... metatable` versus `Titan union ...
metatable`), while the common `Type.Nominal` C representation remains
`Udata *`.

### 3.2 Construction and GC discipline

A synthesized constructor must:

1. receive its adjusted payload through the ordinary static native signature;
2. allocate `luaS_newudata(L, 0, 1_or_2)`;
3. install the canonical union metatable;
4. immediately anchor the fresh userdata in a reserved Lua-stack slot;
5. store the integer tag in `uv[0]`;
6. for a payload, store through the ordinary `setslot` path used by record
   fields; and
7. issue `luaC_barrierback` after a GC-bearing payload store.

This is deliberately not `setboxed`: the payload is opaque to Lua and remains
in Titan's internal representation, exactly like a record field. In
particular, an Array stores its backing `Table *`; only a future/public
Lua-facing accessor would need `copyboxed` to expose the canonical proxy.
Options, functions, nominals, owned values, and supported C scalars/pointers
retain the ordinary `setslot` representation.

The fresh union remains rooted before any later operation that may allocate.
Constructor parameters retain the normal caller/entry roots. Lua's ordinary
userdata traversal marks both user values, so no custom traversal or finalizer
is needed.

### 3.3 Case lowering

The checker first makes any `Union?` force explicit as the ordinary
`Ast.ExpCast` to `Union`; there is no case-specific nil test in the coder. The
generated code then materializes and roots that checked scrutinee once, copies
`ivalue(&u->uv[0].uv)` to a `lua_Integer` temporary, and uses an efficient
dispatch-only C switch:

```c
switch (_case_tag_1) {
case 0: goto _case_1_arm_0;
case 1: goto _case_1_arm_1;
default: goto _case_1_else;
}

_case_1_arm_0: {
    /* ordinary generated Titan block */
    goto _case_1_end;
}
_case_1_arm_1: {
    /* ordinary generated Titan block */
    goto _case_1_end;
}
_case_1_else: {
    /* else, or just goto end when absent */
    goto _case_1_end;
}
_case_1_end: ;
```

Arm bodies must **not** be lexically inside the C `switch`. Titan's ordinary
loop `break` can lower to a C `break;`; placing it inside the switch would
silently exit the switch instead of its enclosing Titan loop. Dispatching to
labels outside the switch preserves existing loop, try/finally, defer, return,
and raise lowering without a parallel break mechanism.

The scrutinee's root remains live until `_case_N_end`. A payload binding reads
`uv[1]` through the normal type-aware `getslot` helper used for record fields
and then enters the same declaration lowering as an ordinary local. It must
not be a hand-written C temporary: bindings may be assigned, captured into a
heap box, rooted, spilled across `setjmp`, or updated through existing
barriers.

Nested cases need unique per-function IDs and disjoint labels.

### 3.4 Compiled-module interface

Add type descriptors:

```lua
Type.Union(name, variants, functions, methods, nvariants)
Type.Variant(fqtn, name, payload, index)
```

`payload == false` distinguishes an empty variant from a variant whose payload
type is `Type.Nil`.

Despite its internal `Type.*` name, `Type.Variant` is member metadata, not a
type accepted by `TypeNominal`, `TypeQualName`, annotations, aliases, `as`, or
`is`. The static type of every constructed value remains the owning
`Type.Nominal`.

`Type.Union.variants` is an ordered list and a name map, like module members.
Each public `Type.Variant.index` stores its absolute 0-based source tag.
`nvariants` retains the total complete declaration count.

Constructors are also ordinary `Type.StaticMethod` entries in
`Type.Union.functions`, alongside user statics. This deliberate duplication
keeps existing static-call, symbol, Lua-entry, and named-argument machinery
intact; `variants` supplies tag/payload metadata for case. First-class
cross-module selectors require the public-closure layout extension below.

Serialization:

- retains public variants in declaration order with absolute indices;
- omits local variants and their local constructors;
- retains `nvariants`;
- sorts function/method maps with `util.bytewise_less`, as records do;
- traverses public variant payloads/statics/methods for C FFI and local-nominal
  leakage;
- registers `Type.Union` in `types.registry` when rehydrating an interface;
  and
- recursively recovers nominal owners referenced through payloads.

Example with a hidden middle variant:

```lua
Union("m.U", {
    Variant("m.U", "first", false, 0),
    Variant("m.U", "last", String(), 2),
}, {
    first = StaticMethod(...),
    last = StaticMethod(...),
}, {}, 3)
```

An importer must never renumber `last` to 1.

#### Public canonical static-closure prefix

The brief requires an imported constructor selector such as
`m.Message.write` to be a first-class value. Current direct imported static
calls work through the native symbol, but current first-class `Type.StaticMethod`
lowering can read a canonical closure slot only for a static declared in the
module being generated. Imported module initialization reconstructs slots for
public top-level function closures, not record statics; falling through to the
module-variable path would be invalid.

The ABI boundary therefore extends the deterministic public prefix of every module
userdata. Allocate, in this exact order:

1. exported module variables in module-member order;
2. canonical closures for exported top-level functions in module-member order;
3. canonical closures for every exported static of every exported record or
   union, iterating nominal module members in module-member order and each
   public `functions` map in `util.bytewise_less` name order; then
4. the existing unconditional Array-metatable slot and all remaining private
   slots.

Variant constructors participate as public union statics. Local statics and
all members of a local nominal remain in the private region and are never
reconstructed by importers.

The producer's upvalue allocator and `import_module` must walk the same shared
layout builder. Rehydration stamps each public `Type.StaticMethod` with its
canonical closure index. The checker/code generator also retains the explicit
import/module-userdata provenance on a qualified selector, so `codevar` reads
the closure directly from that imported module userdata; direct calls continue
to use the native static symbol. Namespace installation and first-class reads
must initially publish/read the same closure slot, preserving function identity
across Titan and the unmodified Lua namespace just as for records.

This general protocol also makes imported record statics first-class rather
than adding a union-only lookup path. It adds no runtime table search and no
new external symbol family, but it is part of the module-layout ABI and
must be documented and tested for source, DSO, archive, transitive-container,
and Lua namespace paths.

### 3.5 ABI boundary and version split

The current authoritative values are distinct:

```text
TITAN_ABI_VERSION     "<active-ABI>"
TITAN_VERSION         "<semantic-version>"
TITAN_LIBRARY_VERSION "<major>.<minor>"
TITAN_PATH_<major>_<minor>
lib/titan/<library-version>
stdlib_<major>_<minor>
```

The rationale recorded in `titan-runtime/titan.h`, the manuals, README, and
`AGENTS.md` is that this ABI boundary adds serialized Union/Variant schemas, the
generated nominal namespace/metatable/tag/payload contract, and the extended
public canonical-static-closure module prefix. Native union values still use
`Udata *`, but an older compiler cannot decode the interface or
generate/consume its constructors, cases, or imported first-class selectors.

Update active-version references coherently in:

- `titan-compiler/driver.lua`;
- `titan-runtime/titan.h`;
- `Makefile`;
- `scripts/stdlib_installer.lua`;
- `.github/workflows/ci.yml`;
- packaging, ABI, driver, static-metadata, compiled-module, and standard
  library specs;
- support/snapshot/production/sanitizer scripts;
- generated/current interface fixtures; and
- all current-version documentation and instructions.

Use a repository-wide audit to classify every stale ABI constant, path suffix,
and environment-variable name. The installer owns only the active versioned
DSO/archive/dSYM and shared generated Lua shims. It does not migrate or inspect
historical layouts. Publication remains transactional, and a synthetic
mismatched provider is rejected before type decoding.

## 4. Compiler architecture and exact change map

### 4.1 Mandatory reading gate for compiler work

Before changing compiler Lua, every implementation agent and every compiler
review agent must read the relevant current implementation chapters, not just
this plan:

- `doc/implementation/ast-typedecl.md`;
- `doc/implementation/lexer-parser.md`;
- `doc/implementation/checker.md`;
- `doc/implementation/type-aliases.md`;
- `doc/implementation/codegen-overview.md`;
- `doc/implementation/codegen-constructs.md`;
- `doc/implementation/values-and-gc.md`;
- `doc/implementation/dense-arrays.md`;
- `doc/implementation/lua-interop-internals.md`;
- `doc/implementation/ffi-internals.md`;
- `doc/implementation/c-ffi-expressions.md`;
- `doc/implementation/error-handling.md`;
- `doc/implementation/defer.md`;
- `doc/implementation/named-arguments.md`;
- `doc/implementation/folder-modules.md`;
- `doc/implementation/multi-module-libraries.md`;
- `doc/implementation/static-compiled-modules.md`; and
- `doc/implementation/driver.md`.

The implementer should then reread the corresponding compiler functions named
below. Reviewers must do the same independently; reviewing only the diff and
this plan is insufficient for a language/runtime feature.

### 4.2 AST shape and parser synthesis

Files:

- `titan-compiler/lexer.lua`
- `titan-compiler/ast.lua`
- `titan-compiler/parser.lua`
- `titan-compiler/syntax_errors.lua`
- `spec/lexer_spec.lua`
- `spec/parser_spec.lua`

Add `UNION`, `CASE`, and `WHEN` keyword tokens while retaining longest-match
behavior for longer identifiers. The `when` token must also be admitted by the
contextual FFI-name machinery described below: ordinary `NAME` still rejects
it, and a contextual spelling must never make `when` legal as a Titan
declaration, local, field, method, or module member.

Generalize the contextual rule instead of special-casing `WHEN`:

1. Add a raw ASCII-identifier capture such as
   `lexer.CNAME = C(identifier)` alongside `NAMEDLABEL`. Keep `NAME` first in
   ordered parser choices, so ordinary non-keywords retain their normal path
   and `CNAME` is significant only when the spelling is a Titan keyword. Add
   `CNAME` to the lexer spec's intentional contextual-overlap exclusion just
   like `NAMEDLABEL`; do not weaken the general longest-match invariant.
2. Add a parser `membername` production which accepts `NAME` or contextual
   `CNAME`, and use it only after `.` in expression suffixes and on the
   right-hand side of a qualified type. Group that choice *before*
   `^NameDotExpSuf` / `^QualName`; otherwise the current labeled `NAME` failure
   commits before the contextual fallback. A small parser action keeps the
   exact name string and marks the resulting
   `Ast.VarDot`/`Ast.TypeQualName` with `_contextual_c_name = true`.
   Declarations, union variants, Titan record fields/statics, colon methods,
   locals, parameters, and module aliases continue to require `NAME`.
3. In `Ast.VarDot`, accept the marker only when the checked receiver is a
   `Type.CModule`, direct C aggregate/pointer/owned object (the existing
   `types.is_direct_c` family), or C type
   namespace, then reuse ordinary foreign-member/`c_field_decl` lookup. In
   `Ast.TypeQualName`, accept it only when the left alias resolves to
   `Type.CModule` and reuse `type_members`. A Titan module, record, union, or
   other receiver gets a focused “Titan keyword is only contextual for a C
   member/type” error even if malformed metadata happened to contain the name.
4. Do not maintain a second C-keyword list. Checker acceptance requires an
   actual imported C member/type/field, so the C parser/toolchain decides which
   identifiers exist. This covers present and future Titan-only spellings such
   as `repeat`, `type`, `record`, and `when`; C-reserved `case` and `union`
   cannot appear in valid imported metadata.

Named C parameter labels already use keyword-inclusive `NAMEDLABEL`, so a
parameter named `when` needs no separate path. Code generation also needs no
keyword branch: existing foreign call/variable/prepared-field emission writes
the exact checked C spelling.

Add:

```text
Ast.TopLevelUnion(loc, name, variants)       -- dynamic islocal
Ast.UnionVariant(loc, name, payload)         -- payload false; dynamic islocal
Ast.StatCase(loc, exp, arms, elseblock)
Ast.CaseArm(loc, name, binding, block)       -- full block; binding false or Ast.Decl
Ast.ExpUnionInit(loc, owner, variant, value) -- internal/synthesized only
```

`Ast.ExpUnionInit` is not source syntax. It is the construction primitive in
the body of a synthesized static and prevents `ExpInitList`'s contextual record
logic from acquiring union-specific modes.

The case-arm and `else` productions must consume the existing `block`
nonterminal, exactly as `if`/`elseif`/`else` do. Do not add a case-specific
statement-list, catch/finally parser, or defer rewrite: `defs.trywrap` and
`defs.simpleblock`/`lower_defers` must produce the same `StatBlock`/`StatTry`
trees and clause-bounded defer tails for both constructs.

`defs.uniondecl` returns the `TopLevelUnion` followed immediately by one marked
`TopLevelStatic` per variant, preserving declaration order:

- `_union_constructor = true`;
- `_union_variant` points to/identifies the source variant;
- empty constructor has no parameters;
- payload constructor has one collision-proof internal parameter and an
  `ExpUnionInit` return body;
- the `TopLevelStatic` checker must ignore that internal declaration spelling
  for API metadata and construct the resulting `Type.StaticMethod` with
  `paramnames = false` (which serialization preserves); and
- constructor `islocal` is `union.islocal or variant.islocal`.

Generalize the record constructor collector to a nominal-constructor collector
which recognizes one adjacent record `new` and a run of union constructors.
Do not infer constructors merely from return type: user statics may also return
their owner.

Add dedicated labels/messages for:

- missing union name;
- missing first variant;
- missing payload type after `:`;
- missing union `end`;
- missing case expression;
- missing first `when`;
- missing variant name;
- missing binding name after `:`;
- missing `then`; and
- missing case `end`.

Every new label must be present in `syntax_errors.lua`; the parser manual notes
that an omitted label otherwise produces a `nil` diagnostic.

### 4.3 Type descriptors and shared nominal helpers

File: `titan-compiler/types.lua`.

Add `Union` and `Variant` to the `typedecl` inventory and a small `types.Union`
wrapper that indexes its ordered variant list by name. Extend:

- `types.serialize`;
- `types.tostring` for descriptor diagnostics;
- `find_c_type` / `first_c_ffi_type`;
- schema/equality traversal where descriptor values are compared;
- local-member omission; and
- deterministic map ordering.

The metadata walkers above traverse `Type.Union` and its `Type.Variant`
entries. Do **not** add either descriptor tag to
`types.has_tvalue_representation`: variants never enter value storage, and a
union value already qualifies through `Type.Nominal`. The checker instead
applies the existing predicate directly to each record `field.type` and union
`variant.payload`, making it the one shared user-value-slot eligibility rule.

Do **not** add a separate union compatibility branch. Existing
`Type.Nominal.fqtn` equality plus `value` compatibility is the required
relation. Existing `Type.Nominal` paths also already provide:

- `types.is_gc`;
- option storage;
- variadic/flexible-value descriptors;
- native `Udata *` C type;
- `value` boxing/unboxing;
- identity equality; and
- explicit nominal-to-C-`void *` identity casts.

Audit all explicit `Type.Record` tests to distinguish:

1. a type namespace (`Type.Record` or `Type.Union`);
2. an instance nominal which may expose record fields only; and
3. common nominal functions/methods/metatable behavior.

Avoid changing a truly record-specific field/constructor path just to remove
the word “record.”

`Type.Variant` must not enter any compatibility, coercion, cast, type-test,
storage, or C-type branch. It is traversed only as metadata owned by
`Type.Union`; every value-facing type remains the owner's `Type.Nominal`.

### 4.4 Checker declaration stages and visibility

File: `titan-compiler/checker.lua`.

Generalize these record-only seams:

- `record_module`, `is_record_visible_from`, and member visibility into nominal
  owner helpers;
- `toplevel_name`, duplicate marking, and name reservation;
- alias-versus-record collision collection into alias-versus-nominal;
- the nominal declaration stage in `checktoplevel`;
- synthesized constructor collection;
- `TopLevelStatic`, `TopLevelMethod`, and `checkmethod`;
- `TypeQualName` imported type resolution;
- `VarDot(Type.Record)` static namespace resolution;
- method-call and bound-method-reference owner checks;
- referenced-record interface recovery into referenced-nominal recovery;
- local-record export leakage into local-nominal leakage;
- public C-FFI traversal;
- `register_module_interface`; and
- `makemoduletype`.

The staged order becomes:

1. reserve ordinary and nominal names / collect aliases;
2. collect imports;
3. resolve aliases;
4. build and register records and unions;
5. collect record and union constructors;
6. collect other function/initializer signatures;
7. collect user statics and methods; and
8. check module variables sequentially.

This lets union payloads be self-recursive or mutually recursive and lets
functions/statics/methods mention unions regardless of textual placement,
without changing module-variable frontiers or combined-AST order.

Preserve the complete existing record/import differential rather than reducing
it to “imports are early”:

- alias targets, record fields, union payloads, and callable signatures resolve
  after all imports have been collected and may name a later import directly;
- ordinary top-level function, method, static, and module-initializer bodies see
  the complete module environment;
- a module-variable annotation and initializer see only earlier imports and
  module variables for direct qualified lookup, and a lambda nested in that
  initializer keeps the same frontier; and
- the module variable may nevertheless use a module-wide alias whose target
  names a later import.

Pair every union case with the equivalent record case so the change cannot
accidentally move either declaration kind across this frontier.

`TopLevelUnion` checking:

- diagnose duplicate variants;
- assign the source ordinal as absolute 0-based tag;
- resolve `payload == false` versus a real type (including `nil`);
- create `Type.Variant` descriptors;
- create/register `Type.Union(fqtn, variants, {}, {}, total)`;
- attach `islocal`;
- later run `checktype` on every payload; and
- reject a payload without `types.has_tvalue_representation`.

Make that last rule a shared checker validation for both record fields and
union payloads, because both are internal userdata user-value slots written by
`setslot`. The current record collector resolves field types but does not
explicitly apply the representation predicate; close that frontend gap rather
than creating a stricter union-only rule. Emit the same owner-kind-adjusted
diagnostic for a direct C aggregate/array/function or C function pointer before
code generation. Direct C aggregates/functions have no supported `setslot`
branch. C arrays and function pointers currently reach pointer-shaped coder
branches, so rejecting them is an intentional record-field compatibility
tightening that avoids array-decay/lifetime and function-pointer-to-`void *`
representation; audit repository sources/specs and document it explicitly.
Exact C `TValue` remains the deliberate direct-aggregate exception.

Static/method collection must distinguish owner kind for diagnostics and apply
the three-way variant/static/method collision set. Rename the checker-only
`node._record` decoration to a neutral owner decoration rather than putting a
union into a misleading record slot.

Owner locality is transitive for generated and user-written members. When a
union is local, force every constructor, static, and method to be local on
both its AST node and its `Type.StaticMethod`/`Type.Method` descriptor,
regardless of whether the member declaration itself wrote `local`. This must
happen before interface and external-symbol collection: code generation keys
native/Lua wrapper publication from the AST flag, so descriptor-only privacy
would still leak symbols for a local union.

`VarDot` behavior:

- a `Type.Union` namespace finds constructor/user static functions;
- a `Type.Nominal` record still finds visible fields;
- a `Type.Nominal` union gives a clean “union values have no fields; use case”
  diagnostic; and
- contextual `{ ... }` construction under a union nominal is rejected cleanly
  instead of entering record-field matching.

In `typefromnode`, distinguish a local union member selector used where a type
is required. A variant or static such as `Message.move` is not a type; report a
dedicated diagnostic (including under `as`/`is`) that names the owning union
and directs the programmer to `Message` or `case`. Do not construct a
variant-refinement `Type.Nominal`, and do not register variants in the type
namespace.

Keep the current type grammar at `Name` or `Name.Name`; do not add a
three-component type solely for recovery. Consequently an imported union type
`m.Message` is legal, while an imported variant spelling `m.Message.move`
receives the existing parser-level type-syntax error in an annotation or on the
RHS of `as`/`is`. Test both local semantic rejection and imported parser
rejection for both operators, and ensure neither form is reinterpreted as a
value test.

Add an `Ast.ExpUnionInit` arm to the expression checker. It must validate the
resolved owner/variant decorations, check/read the synthesized payload
parameter through ordinary `VarName` handling (so it is marked used and any
capture/read walkers see it), and assign the result
`Type.Nominal(union.name)`. Extend every checker and coder expression walker
that enumerates child expressions to recurse into its optional payload.
Parser synthesis alone is insufficient: the generated constructor body still
passes through ordinary body checking before code generation.

Refine the module-constant `isconstructor`/`isconst` path at the same time.
Today it accepts any `Type.StaticMethod` with one non-flexible owner-nominal
result, which accidentally admits a user static that merely returns its owner.
Recognize constructors through the registered nominal descriptor and
parser/interface-proven relationship instead:

- `Type.CPseudoNew` keeps its current treatment;
- a record constructor is the validated synthesized `new` for that record;
- a union constructor is the validated static paired with a variant of the same
  owner/name/signature from §4.9; and
- all other statics are nonconstructors, regardless of result type.

This must work for same-module and imported source/DSO/archive descriptors
without adding an independently forgeable “returns owner” heuristic. Then
reuse the existing recursive constant-argument check, accepting the exact §0.2
initializers and rejecting nonconstant payloads and owner-returning user
statics.

### 4.5 Case checking and decorations

First repair the existing checker-to-coder reachability boundary for every
statement kind, rather than adding a case-only exception. Refactor
`checkstat` through one wrapper (or an equivalent single chokepoint) that
records its existing boolean result as `node._always_returns` on every checked
statement. This decoration means exactly what `checkstat` already means:
control cannot continue because every path returns or raises from the
containing function. It does not turn `break` into an always-return result and
does not add a new dead-code diagnostic.

The shared decoration is required because `checkblock` deliberately
short-circuits after any true result, including an all-returning `StatBlock`,
`StatIf`, or `StatTry`; statements after those compounds are therefore just as
unchecked as statements after the new `StatCase`. The coder must consume the
same decoration for all four compounds. Direct `StatBreak` remains a coder
terminator under its existing separate rule.

Add a `StatCase` checker arm that:

1. checks its expression once in scalar demand;
2. replaces the checked expression with `tryforce(node.exp)`, materializing the
   ordinary `Union? -> Union` `Ast.ExpCast` and its run-time nil check;
3. requires the resulting exact nominal to resolve to a visible registered
   union; any visible exact union is valid, but there is no coercion from
   `value`/records or between union identities;
4. attaches the resolved `Type.Union` to the statement;
5. resolves each arm through `union.variants[name]`;
6. rejects a missing variant (including an omitted local variant from an
   imported interface) with the ordinary unknown-variant diagnostic—an
   importer cannot distinguish a hidden spelling from one that never
   existed—and rejects a second resolved arm with a dedicated duplicate-arm
   diagnostic that points back to the first arm;
7. attaches the `Type.Variant` and absolute tag to each arm;
8. opens a fresh scope per arm;
9. for a payload binding, assigns its payload type and declares it in the arm
   scope before checking the full block, making it visible to that arm's
   protected body/catch/finally while letting ordinary capture analysis
   observe it;
10. rejects an empty-variant binding;
11. checks each arm and `else` through ordinary `checkstat` on the full
    `StatBlock`/`StatTry`, in its own arm scope; and
12. returns the closed-union always-return result from §2.6 through the shared
    `checkstat` decoration protocol; do not stamp or interpret a case-specific
    termination flag.

The binder must be a real `Ast.Decl`, not an ad hoc name decoration. That is
what makes assignment, closure capture, unused-local tracking, GC rooting, and
setjmp spill analysis reuse current behavior.

Extend every checker/type walker that enumerates statement children or
declaration types. Add clean recovery types after errors so a bad arm does not
crash later arms.

### 4.6 Code-generator nominal plumbing

File: `titan-compiler/coder.lua`.

Keep the existing `Type.Nominal` value paths:

- `getslot`;
- `checkandget` / `checkandset`;
- `setslot` / `setboxed` (both remain shared nominal machinery, but union
  payload storage specifically uses internal `setslot`);
- `ctype`;
- call argument/result lowering;
- option and `value` boundaries; and
- FFI identity casts.

Generalize:

- `type2metatable` metadata from `fqtn -> slot` to
  `fqtn -> { slot, kind }`;
- imported metatable recovery, currently hard-coded to
  `"Titan record <fqtn> metatable"`;
- `record_namespace_slots` into nominal namespace slots;
- namespace creation and read-only module registration for public unions;
- installation of public statics/constructors in that namespace;
- `allocate_upvalues` and `import_module` through one deterministic
  public-prefix enumerator that includes public record/union static closures;
- `codevar` for a qualified imported `Type.StaticMethod`, using its reconstructed
  closure index plus the selector's imported-module userdata provenance;
- trace-name comments/diagnostics where “record function” becomes “nominal
  static” or owner-kind-specific text;
- `external_symbols` and `interface_external_symbols`; and
- all AST passes which recognize `TopLevelRecord` when the operation is really
  “nominal declaration.”

Retain record-only code for field maps, record getters/setters, and record
literal construction.

Add a union metatable builder parallel to `coderecorddec`:

- distinct registry/protected names;
- reverse metatable-pointer-to-fqtn registration for mismatch diagnostics;
- a lookup table containing public methods only;
- `__index` returns method closures or raises “member not found in union”;
- `__newindex` always raises; and
- no tag/payload entry is ever installed.

Method native signatures and bound trampolines already use `Udata * self` and
should be reused, not duplicated.

Do not implement imported constructor values with a Lua table lookup or a
fresh closure at each reference. Producer namespace installation, same-module
selection, imported selection, and Lua exposure all point at the one canonical
closure allocated by the public-prefix protocol in §3.4.

### 4.7 Constructor lowering

Add the internal `ExpUnionInit` expression handler:

- assert it belongs to a synthesized constructor and has resolved union/variant
  decorations;
- reserve/reuse a GC result temporary exactly like `coderecord`;
- allocate one or two user values;
- set metatable and anchor immediately;
- set `uv[0]` to the variant index;
- if present, evaluate/read the already-adjusted constructor parameter once and
  store its internal representation with `setslot` into `uv[1]`, exactly as
  `coderecord` stores a field;
- add the same `types.is_gc(payload)`-guarded `luaC_barrierback` used for a
  GC-bearing record-field store; and
- return the `Udata *`.

Do not route the opaque payload through `setboxed`/`copyboxed`. Those helpers
exist for Lua-visible boundaries and would turn an Array's internal `Table *`
into a proxy `Udata *`, unlike a record field. The case binder reverses the
internal store with `getslot`.

For an Array payload, generated-C assertions are part of the representation
proof: construction must use the record-style `sethvalue` slot copy, binding
must recover it with `hvalue`, and neither path may emit
`titan_array_require_proxy`, `copyboxed`, or mixed/proxy unboxing. Payload
opacity means behavioral tests alone cannot distinguish those representations.

Because the surrounding declaration is an ordinary `TopLevelStatic`, this
automatically reuses:

- direct native static calls;
- Lua entry wrappers;
- missing/surplus argument adjustment;
- first-class canonical closures and exact/generic dispatch;
- public/local symbol policy;
- module namespace installation; and
- constant top-level initialization recognition through the validated
  record/variant constructor relationship.

Add focused generated-C assertions, but make behavioral/GC tests authoritative.

### 4.8 Case code generation and control-flow traversals

Before adding emission, update every coder traversal that can see statements:

- `is_terminator`, and therefore `last_reachable_stat` / `codestats`;
- `collect_reads_stat`;
- `collect_writes_stat`;
- `analyze_try_spills_block`;
- `stat_contains_try`;
- any local/capture predeclaration pass; and
- `codestat_dispatch`.

Read analysis includes the scrutinee and every arm. Write/spill/try analysis
recurses through every arm and `else`, including arm-local catch/finally and
parser-lowered defer tails. Write analysis must also register each payload
binder as an ordinary declaration/write before traversing its block, so a
binder assigned in a protected body and read by that arm's catch/finally uses
the existing spill proof.

The checker deliberately leaves statements after any always-returning
statement unchecked. Generalize `is_terminator` to recognize the shared
`node._always_returns` decoration, in addition to the existing direct
`StatBreak` rule. This repairs the same latent boundary for `StatBlock`,
`StatIf`, and `StatTry` while adding `StatCase`, and makes `codestats`, read and
write collection, try-spill analysis, `last_reachable_stat`, and
`unreachable_return` stop at exactly the checker's boundary. Do not re-derive
if/try/case branch coverage in the coder.

Case emission:

1. use the existing materialization helper to evaluate and root the
   checker-rewritten scrutinee (including any option-force cast) once;
2. copy the integer tag once;
3. emit only tag-to-label gotos inside the switch;
4. emit labeled, braced arm blocks outside the switch;
5. retain the union root through the end label;
6. push a stack-depth scope and spill scope for each labeled arm, place the
   binder declaration and arm block in the same outer C lexical block, then
   pop both scopes before generating the sibling arm;
7. initialize a binder through the ordinary declaration machinery, preserving
   declaration boxes, GC slots, and `spill_decl_zero`/update behavior; and
8. end every falling-through arm with an explicit goto to the case end.

Generate the arm with ordinary `codestat` on its full block node, just as an
`if` branch does; do not iterate a presumed plain statement list. This
preserves the existing `StatTry` protected-boundary stack, pending
return/break routing, spill analysis, and parser-lowered defer behavior before
the case's no-fallthrough jump.

If ordinary declaration emission cannot accept a precomputed payload source,
refactor it into a shared helper or introduce a checker-created internal
payload expression. Do not hand-emit a reduced binder path: a binder may be
captured, reassigned, GC-bearing, or live across a protected boundary.

Required adversarial regression:

```titan
while true do
    case message
    when quit then
        break
    else
    end
    unreachable_if_quit()
end
after_loop()
```

It must reach `after_loop`, not merely exit the generated switch. Also cover a
loop declared inside an arm, nested cases, and try/finally/defer around breaks
and returns.

### 4.9 Interfaces, providers, and installer

Files include:

- `titan-compiler/driver.lua`
- `titan-compiler/staticmetadata.lua`
- `titan-runtime/titan.h`
- `Makefile`
- `scripts/stdlib_installer.lua`
- `.github/workflows/ci.yml`
- compiled-module/static-provider specs and fixtures

Extend decoded-interface validation and registration for `Type.Union`.
Static metadata bytes need no new container version; their serialized types
are gated by the compiled-module ABI.

Reject malformed recovered unions before registering or generating from them.
Validation must prove:

- the union's fqtn is the canonical `<module>.<member>` owner name;
- `nvariants` is a positive integer, even when every variant is local and the
  public array is empty;
- the public variant array is dense and its name index maps each spelling to
  the identical descriptor;
- every entry is a `Type.Variant` owned by that union, with a nonempty unique
  name and a unique integer absolute index in `[0, nvariants)`;
- gaps in absolute indices are accepted without renumbering; a decoded public
  interface contains no evidence that could distinguish an omitted local
  variant from another omitted declaration; and
- each public variant has a matching public `Type.StaticMethod` constructor
  under the same name: zero parameters for an empty variant or exactly its
  payload type for a payload variant, no variadic/flexible shape,
  `paramnames == false`, and exactly one `Type.Nominal(union.name)` result.

These are logical interface invariants, not just serialization shape checks.
In particular, reject duplicate imported absolute indices before a case could
emit duplicate C labels. Separately, producer-side interface construction must
compare the full source union with the public result and prove that it omitted
exactly local variants and their constructors. Do not claim the decoder can
recover that lost locality fact.

Run a recursive decoded-interface type-graph validator with an explicit
descriptor context. A `Type.Variant` is legal only as the direct indexed/name
entry owned by a `Type.Union.variants` collection. Reject it if recovered as a
module member or variable, alias target, record field, union payload, callable
parameter/result, option/container component, nested function component, or any
other value-facing type—even when a malformed serializer constructs the
descriptor directly and bypasses source `typefromnode`. Constructor signatures
contain only the payload type and owning `Type.Nominal`; they never expose the
variant descriptor.

Do not serialize a free-standing constructor boolean solely for constant
expression checking. Generalize nominal-interface validation so the existing
record `new` descriptor is tied to its owner/ordered fields and each union
constructor is tied to its owner/variant as above. The checker queries that
validated relationship. A malformed imported static cannot acquire constructor
constness merely by returning its nominal owner.

Test source, DSO, regular archive, prefix-container, and transitive nominal
recovery. `coder.interface_external_symbols` must enumerate public union
constructors/statics, method natives, and bound-method entries so provider
collision preflight matches AST-based compilation.

Perform the active-path sweep from §3.5. Keep publication transactional
inside the active library directory, use `stdlib_<major>_<minor>` for the stale-layout
name, and do not add links or compatibility copies.

## 5. Documentation deliverables

Documentation is part of the feature, not follow-up work.

### 5.1 New chapters

Add and link:

- `doc/language/unions.md`
- `doc/implementation/unions.md`

The language chapter is normative for:

- declaration/variant syntax;
- `when` arm syntax and its contextual C-identifier exception;
- corrected same-module and two-module `import`/`float` constructor examples,
  including the required parentheses around a record payload;
- nominal typing and compatibility, including that variants are not types or
  legal `as`/`is` targets;
- exact record-parity declaration frontiers and visibility/local variants;
- constructors, statics, methods, first-class/bound values;
- positional-only payload constructor policy (`paramnames = false`);
- module-constant eligibility for genuine synthesized constructors, with
  nonconstant arguments and owner-returning user statics rejected;
- the exact record-field/union-payload user-value eligibility rule, including
  accepted C scalar/object-pointer/`TValue`/`Udata *`/owned shapes and rejected
  direct aggregate/array/function/function-pointer shapes;
- case syntax, scoping, binding copy/alias semantics, non-exhaustiveness, and
  control flow, including exact `if`-block catch/finally/defer parity;
- immutability and identity equality;
- automatic `Union?` forcing plus value/FFI boundaries;
- Lua behavior; and
- limitations of v1.

The implementation chapter covers:

- AST/parser synthesis;
- Type.Union/Variant and serialization;
- checker staging/frontiers/privacy;
- constructor/static/method reuse;
- Udata/metatable/user-value layout;
- anchoring/barriers and record-identical internal `setslot`/`getslot`
  payload representation, including raw internal Array backing tables;
- dispatch-only switch lowering;
- binder declaration/capture/spill behavior;
- source/DSO/archive rehydration;
- deterministic public static-closure prefix and imported selectors;
- the shared checker-to-coder always-return decoration used by block, if, try,
  and case statements; and
- the ABI boundary.

Use the variadic-parameters chapters as the completeness model.

### 5.2 Existing language-manual updates

At minimum audit and update:

- `doc/language/index.md`
- `doc/language/grammar.md`
- `doc/language/types.md`
- `doc/language/records.md`
- `doc/language/functions.md`
- `doc/language/named-arguments.md`
- `doc/language/closures.md`
- `doc/language/statements.md`
- `doc/language/expressions.md`
- `doc/language/error-handling.md`
- `doc/language/defer.md`
- `doc/language/option-types.md`
- `doc/language/type-aliases.md`
- `doc/language/arrays-maps.md`
- `doc/language/philosophy.md`
- `doc/language/modules.md`
- `doc/language/folder-modules.md`
- `doc/language/lua-interop.md`
- `doc/language/ffi.md`
- `doc/language/c-ffi-expressions.md`
- `doc/language/multi-module-libraries.md`
- `doc/language/static-compiled-modules.md`

Update the reference/compiler semantic version and its derived active library
paths independently. The defer chapter must list case arms and `else`
as ordinary block consumers with the same clause-bounded transformation as
`if` branches. The option chapter must include case as an ordinary forced
bare-value context. The type/cast chapters must distinguish the union type from
its non-type variants. The FFI chapters must document the generalized
metadata-backed contextual C-name rule, using `when` plus an older Titan-only
spelling such as `repeat` or `type`, without making any keyword an ordinary
Titan identifier.
The modules, records, type-aliases, functions, and new union chapters must show
the exact declaration-frontier matrix from §0.3, including later imports in
fields/payloads/signatures, the direct module-variable and nested-lambda
frontier, and the legal alias bridge to a later import.

The records and FFI chapters must replace any broad claim that a local record
field may contain any C type with the exact shared user-value-slot eligibility
rule. They must call out the clean rejection of direct C aggregates, arrays,
functions, and function pointers and the accepted exact `TValue` exception.
This is a frontend consistency fix exposed by requiring union payload parity,
and the array/function-pointer cases are an intentional compatibility
tightening rather than a union-only restriction.

The modules/expressions/records/new-unions material must also document the
refined constant-expression rule: a validated synthesized record or union
constructor with recursively constant arguments is allowed in a module-variable
initializer, but an ordinary owner-returning static is not.

### 5.3 Existing implementation-manual updates

At minimum audit and update:

- `doc/implementation/index.md`
- `doc/implementation/ast-typedecl.md`
- `doc/implementation/lexer-parser.md`
- `doc/implementation/checker.md`
- `doc/implementation/type-aliases.md`
- `doc/implementation/codegen-overview.md`
- `doc/implementation/codegen-constructs.md`
- `doc/implementation/values-and-gc.md`
- `doc/implementation/dense-arrays.md`
- `doc/implementation/lua-interop-internals.md`
- `doc/implementation/ffi-internals.md`
- `doc/implementation/c-ffi-expressions.md`
- `doc/implementation/error-handling.md`
- `doc/implementation/defer.md`
- `doc/implementation/named-arguments.md`
- `doc/implementation/driver.md`
- `doc/implementation/folder-modules.md`
- `doc/implementation/multi-module-libraries.md`
- `doc/implementation/static-compiled-modules.md`
- `doc/implementation/string-library.md`

Update the AST/type inventories and known-limitation tables, including the fact
that case exhaustiveness is not required or diagnosed while complete static
coverage can prove non-fallthrough. Update the checker and code-generator
chapters to document the shared `_always_returns` reachability boundary and
remove any implication that the coder recognizes only direct
return/break/raise statements; retain the documented limitation that dead
tails after an always-returning compound are not typechecked.
The implementation defer chapter must likewise update its parser-consumer
inventory and make explicit that case reuses `block`/`simpleblock`,
`trywrap`, and `lower_defers` unchanged.
The lexer/parser and FFI chapters must describe the general raw `CNAME`
category, its AST marker, its checker-only C-context gate, and why code
generation continues to emit the stored spelling unchanged. Update any claim
that `NAMEDLABEL` is the only keyword-inclusive lexical context. The
checker/GC chapters must also record the one
`types.has_tvalue_representation` rule shared by record fields and union
payloads, and the internal `setslot`/`getslot` representation rather than a
Lua-boxed payload boundary.

The checker/type-alias chapters must spell out the declaration-frontier
differential and nested-lambda exception from §0.3. The AST/type/interface
chapters must state that `Type.Variant` is union-owned metadata only, is never a
value-facing type, and is rejected recursively if recovered elsewhere in a
compiled interface. The parser chapter must record the deliberate local
semantic versus imported three-component parser-error behavior for
variant-looking type targets.
The checker and compiled-interface chapters must document constructor
recognition through validated nominal metadata for constant expressions, not
through the current broad owner-result heuristic.

### 5.4 Repository-facing documentation

- Remove the README “tagged variants” roadmap item and describe shipped
  unions/case in the feature list.
- Update README installation paths and the ABI section to the current split values.
- Update `AGENTS.md` with the union architecture, spec locations, test
  placement, active paths, ABI rationale, retirement of the old migration
  smoke, and its replacement producer-preparation duties.
- Retain the feature rationale without a historical numbering timeline.

All manual examples should be compiled in tests or copied from tested fixtures
where practical. In particular, do not reintroduce `number`, Titan-side
`require`, `if`/`elseif` case arms, or flattened named record payloads.
Compile the exact two-module `local m = import "messages"` example from §0.2,
including `m.Message.move({ x = 1.0, y = 2.0 })`, and pair it with a rejected
named-call form so the prose cannot drift from positional-only metadata.

## 6. Dogfooding: regular-expression AST

### 6.1 Mandatory reading gate for Titan source work

The regex conversion is work in **Titan source**, not compiler Lua. Before
editing or reviewing it, the dogfood implementation agent and dogfood review
agent must read the relevant current language manual, including the new chapter
created by this feature:

- `doc/language/unions.md` (mandatory, as written on the branch);
- `doc/language/records.md`;
- `doc/language/types.md`;
- `doc/language/type-aliases.md`;
- `doc/language/arrays-maps.md`;
- `doc/language/statements.md`;
- `doc/language/error-handling.md`;
- `doc/language/defer.md`;
- `doc/language/functions.md`;
- `doc/language/named-arguments.md`;
- `doc/language/closures.md`;
- `doc/language/modules.md`;
- `doc/language/folder-modules.md`;
- `doc/language/standard-library-string.md`; and
- `doc/language/grammar.md`.

They must treat those language chapters, not compiler-internal shortcuts, as
the source contract. The dogfood phase begins only after the core union docs,
compiler tests, and cross-module behavior are green.

### 6.2 Bounded conversion

Current target:

- `titan/string/regex_parser.titan`
- `titan/string/regex_compile.titan`

Keep public `titan.string` APIs, parser grammar, limits, diagnostics, source
roster, and regex behavior unchanged. Within the two target files, keep every
non-`RegexNode` record unchanged: `ParsedRegex`, `RegexQuantifier`,
`RegexClassItem`, `RegexParseFrame`, `RegexParseState`, and
`RegexCompileState`. Records in other `titan.string` contributors are outside
this bounded conversion.

Replace the integer kind constants and broad mutable `RegexNode` record with
one module-local union plus narrowly shaped module-local records:

```titan
local record RegexTextNode
    position: integer
    text: string
end

local record RegexChildrenNode
    position: integer
    children: {RegexNode}
end

local record RegexGroupNode
    position: integer
    number: integer
    child: RegexNode
end

local record RegexRepeatNode
    position: integer
    minimum: integer
    maximum: integer
    child: RegexNode
end

local record RegexBackreferenceNode
    position: integer
    number: integer
    nullable: boolean
end

local union RegexNode
    empty: integer
    literal: RegexTextNode
    any: integer
    class: RegexTextNode
    sequence: RegexChildrenNode
    choice: RegexChildrenNode
    group: RegexGroupNode
    repetition: RegexRepeatNode
    backreference: RegexBackreferenceNode
    word_start: integer
    word_end: integer
end
```

`repeat` is already a reserved word, so the private variant uses
`repetition`. The simple variants use their position integer directly to avoid
an extra payload-record allocation; the specialized records retain only data
that their variants actually use.

Add `RegexNode:position(): integer`, implemented with `case`, so diagnostics
which currently read `child.position` remain direct and explicit. Replace the
current reuse of `minimum` as a backreference-nullability flag with the
`nullable` boolean. Mutating that payload record through a case binding
deliberately exercises the specified reference-payload alias rule.

Convert these dispatch cascades to explicit cases:

- `regex_nullable`;
- `regex_validate_backreference`;
- `regex_projected_size`; and
- `regex_compile_node`.

Convert helper construction sites to fully initialized variant constructors.
Remove `regex_node` and the integer `REGEX_*` constants. Do not retain a
shadow integer kind or a generic all-fields payload record; either would defeat
the dogfood objective.

Use explicit arms for every known regex variant in the total dispatches:
`RegexNode:position`, `regex_nullable`, `regex_projected_size`, and
`regex_compile_node`. Their complete closed-union coverage must satisfy the
return analysis without defensive impossible `else` errors.
`regex_validate_backreference` is intentionally a partial one-arm case with
no noise arms; it is the dogfood proof that non-exhaustive cases fall through.
This control-flow proof must not become a requirement that cases be exhaustive.

This also proves folder composition: `regex_compile.titan` sorts before
`regex_parser.titan`, yet the folder ensemble is checked once. Union
predeclaration must behave like record predeclaration across contributors.

`spec/libuv_build_spec.lua` has a source-text declaration classifier used to
assert stdlib public/private shape. Teach it to recognize unions and assert
that `RegexNode` and all payload records remain module-local. The Makefile
source roster remains unchanged.

If dogfooding exposes a compiler defect, first reduce it to a small focused
checker/coder regression, fix the central compiler invariant, and only then
resume the regex conversion. Do not add regex-specific compiler behavior.

## 7. Test plan

### 7.1 Lexer and parser

`spec/lexer_spec.lua`:

- exact `union`/`case`/`when` keyword tokens;
- keyword-prefix identifiers remain names;
- named-call labels may still spell keywords under their dedicated lexer rule,
  including `when`;
- `CNAME` captures raw contextual C identifiers, remains an intentional
  overlap excluded from the ordinary token-uniqueness assertion, and does not
  weaken `NAME`; and
- existing keyword/token uniqueness checks.

`spec/parser_spec.lua`:

- public/local unions;
- empty/payload/local variants and optional semicolons;
- at-least-one-variant diagnostic;
- recursive payload syntax;
- synthesized constructor count/order/flags/locality/internal bodies;
- `payload == false` versus `TypeNil` source nodes;
- one or more `when` arms, binding, and optional `else`;
- arm-local and else-local `catch`, `finally`, and combined trailers, with the
  same AST shape as corresponding `if` branches;
- `defer` lowering independently bounded to an arm body, catch, or finally,
  never swallowing a later clause or arm;
- an ordinary nested `if` inside an arm followed unambiguously by another
  `when` arm;
- contextual C member/type spellings named `when`, with the exact name and
  `_contextual_c_name` marker preserved on the AST;
- local two-component variant-looking type targets remain parseable for checker
  diagnostics, while imported three-component `m.Message.move` targets on both
  `as` and `is` receive the intentional type-syntax error;
- nested cases and cases in loops/try/defer blocks;
- all new labeled failures and locations;
- no union/case declarations in illegal positions; and
- existing record/if parsing regressions.

Extend `spec/ctypes_spec.lua` and
`spec/checker/named_arguments_spec.lua` so a C parameter named `when` retains
its exact metadata and works through the existing named-label path. Extend
`spec/checker/c_ffi_spec.lua`, `spec/coder/c_ffi_spec.lua`, and, where the
named-call execution fixture naturally belongs,
`spec/coder/named_arguments_spec.lua`, with one small header that uses
Titan-only C identifiers across the directly emitted representative classes:

```c
typedef int type;
typedef struct holder { type when; } holder;
static type when(type when) { return when; }
static type repeat = 7;
```

Titan must resolve `c.type`, `h.when`, positional `c.when(h.when)`, and named
`c.when { when = h.when }`, read `c.repeat`, emit their exact C spellings, and
run correctly. Add focused checker coverage for an enum constant/object macro
keyword spelling, which shares the CModule ordinary-member selector. Negative
cases prove `r.when` on a Titan record, `u.when` on a Titan union value, and
`m.when` on a Titan module receive the focused contextual-C-name diagnostic
rather than making keywords general member names. A Titan-module-qualified
type position such as `local x: m.when` (and its cast equivalent) separately
proves the marked `TypeQualName` gate; only a `Type.CModule` alias may admit it.
The older `repeat` case proves this is a shared FFI rule, not a `when`
exception.

In the same checker FFI suite, extend the existing local-record-field coverage
to prove the shared user-value-slot predicate: record fields and union payloads
accept the same C scalar/object-pointer/exact-`TValue`/`Udata *`/owned cases and
both reject direct C aggregates, arrays, functions, and function pointers before
code generation. Audit all existing Titan sources and C-FFI specs for record
fields using the newly rejected array/function-pointer shapes; migrate only
intentional fixtures and preserve an explicit compatibility regression.

### 7.2 Types and checker

`spec/types_spec.lua`:

- Union/Variant constructor shapes;
- ordered/name-indexed variants;
- empty versus nil payload serialization;
- deterministic round-trip;
- local variant/constructor omission with original tag holes and `nvariants`;
- malformed recovered fqtn/list-map/name/index/count/constructor combinations,
  including duplicate absolute indices rejected before code generation;
- recursively malformed interfaces which place a `Type.Variant` in a module
  member/variable, alias, record field, union payload, option/Array/Map, or
  nested callable input/result instead of directly in its owning union's
  variant collection;
- decoder acceptance of unexplained in-range tag gaps without renumbering, and
  producer-side proof that source serialization omits exactly local
  variants/constructors;
- statics/methods sorted deterministically;
- public C/local nominal traversal through payloads;
- nominal/value compatibility;
- distinct-union and record/union incompatibility;
- `Type.Variant` remains metadata and never participates in compatibility,
  storage, or cast/type-test relations;
- GC/TValue/FFI identity predicates for union values.

Add `spec/checker/unions_spec.lua`:

- one/many empty and same-type variants;
- self and mutual recursion, including later declarations/folder order;
- constructor signatures, `paramnames == false`, and positional-only named-call
  rejection;
- the exact two-module §0.2 fixture using
  `local m = import "messages"` and
  `m.Message.move({ x = 1.0, y = 2.0 })`, plus rejected named-call syntax;
- module-constant acceptance for direct/imported record and union synthesized
  constructors with constant arguments, and rejection for nonconstant payloads
  and ordinary owner-returning statics;
- synthesized `ExpUnionInit` result/payload checking with no false unused
  internal parameter;
- missing-nil and surplus-evaluation adjustment;
- first-class constructor exact and gradual-call types;
- user statics, methods, implicit self, and bound references;
- every variant/static/method collision;
- local union direct/indirect export rejection through every public type shape;
- local-union owner locality forced onto unmarked constructors/statics/methods
  in both AST and descriptors;
- public union with local variants and local payload types;
- public variant C/local-type leakage rejection;
- shared record-field/union-payload user-value eligibility: accept the same
  Titan and boxable C types, reject direct C aggregates/arrays/functions and C
  function pointers in both owner kinds before code generation;
- imported qualified union access and the exact record-parity frontier matrix:
  a later import is accepted directly in an alias target, record field, union
  payload, callable signature, and ordinary top-level body; direct qualification
  is rejected in a module-variable annotation/initializer and its nested lambda;
  and the same module variable may use an alias whose target names that later
  import. Pair every case against the equivalent imported-record case;
- transparent local/public aliases to unions, including use in a case and
  rejection of an alias as a constructor/static runtime namespace;
- clean rejection of local variants in an alias, record field, union payload,
  option base, Array element, Map key/value, and nested function input/result,
  while the owning union remains legal in every corresponding recursive type
  position;
- local `Message.move` semantic rejection and imported `m.Message.move`
  parser-level type-syntax rejection on each RHS of `as` and `is`;
- owning-union `as`/`is` checks reuse ordinary nominal identity for direct,
  `value`, option-unwrapped, wrong-union, and record operands;
- local variant invisible to importers;
- exact-union case scrutinee after ordinary forcing: accept any visible
  `Union` and `Union?`, materialize the latter's `Ast.ExpCast`, and reject
  `value`/records without coercion;
- two distinct unions with same-spelled variants both case successfully within
  their own descriptor, while an arm name unique to the other union cannot
  cross-resolve;
- visible/unknown/local/repeated arm names;
- payload arm with/without binding and empty arm with illegal binding;
- binding type, scope, assignment, shadowing, capture, and unused-local behavior;
- binding visibility across its arm's body/catch/finally, body-local
  invisibility in sibling handlers, implicit catch locals, bare re-raise, and
  finally-transfer diagnostics exactly matching an `if` block;
- no direct payload/variant field access;
- clean rejection of contextual `{}` as a union;
- non-exhaustive fallthrough plus closed-union always-return analysis, including
  complete local/aliased coverage, a redundant falling-through `else`, and an
  imported hidden variant that prevents visible-arm coverage;
- all-returning nested block, if/else, try, and case statements followed by
  unchecked dead syntax, proving that each receives the same shared
  `_always_returns` decoration and reaches the same checker boundary;
- alias/re-export/transitive nominal recovery;
- valid nominal identity C-`void *` cast and unrelated-cast rejection; and
- error recovery after multiple bad arms.

Extend `spec/checker/so_rehydration_spec.lua` and static-compiled-module checker
specs for public Union registration, constructor metadata, hidden tag holes,
case checking, and transitive nominal payload owners.

### 7.3 Code generation, runtime, GC, and Lua

Add `spec/coder/unions_spec.lua`, grouping cases to limit native rebuilds:

- exact 0-based tags;
- `nuvalue == 1` for empty and `nuvalue == 2` for payload, including typed nil;
- primitive, string, Array, Map, record, union, function, value, option,
  pointer/owned, and recursive payloads;
- exact C `TValue`, `Udata *`, and owned payloads under both full and
  generational GC;
- `Array?` payloads in both present and nil states under both GC modes, proving
  the raw backing-`Table`-or-nil internal option representation and barrier;
- record-identical internal payload slots, including an Array remaining its
  backing `Table *` in `uv[1]` rather than becoming a Lua-facing proxy;
- `Union?` present-value dispatch and nil failure through the ordinary option
  cast; on nil assert the exact source-located
  `expected <fully-qualified-union> but found nil` error and zero arm, `else`,
  arm-`catch`, and arm-`finally` side effects;
- owning-union `as`/`is` run-time success/failure through the existing nominal
  metatable path, with no variant-target code-generation branch;
- single scrutinee evaluation with observable side effects on both present and
  nil option-force paths;
- selected arm only, no fallthrough, else, and no-else continuation;
- payload binding copy and reassignment versus reference-payload mutation;
- binding captured by a closure and surviving GC;
- sibling arms with captured/spilled bindings, proving stack-depth, box, and
  active-spill state does not leak between arm scopes;
- full and generational GC during construction, slot storage, case extraction, and
  arm execution;
- direct/local/imported/first-class constructor calls, missing nil, evaluated
  surplus, and exact/generic paths;
- compiled execution of the exact §0.2 `import`/`float`/parenthesized-record
  fixture, with the named-call rejection remaining a checker test;
- imported constructor-selector identity and calls through source, DSO, and
  archive dependencies, plus an imported record-static first-class regression
  for the generalized protocol;
- deterministic public module-slot reconstruction for top-level functions then
  public record/union statics, with local nominal/member closures excluded;
- direct union methods and bound-method values;
- case nested in a loop with `break` (mandatory);
- loop nested in an arm, nested case, return, raise, defer, catch/finally, and
  spill-sensitive locals;
- differential dead-tail code-generation tests for all-returning nested
  `do` blocks, `if`/`else`, `try`, and `case`: each must omit the unchecked
  tail without dereferencing missing checker decorations, while a compound
  that can fall through must still emit and execute its checked successor;
- differential `if`/`case` cleanup tests for arm-local defer and
  catch/finally on fallthrough, return, enclosing-loop break, and raise,
  including composition of defer with explicit handlers;
- handler isolation between arms and from scrutinee evaluation, plus
  else-arm trailers;
- identity equality;
- Lua namespace constructors/statics, method lookup, protected metatable,
  payload opacity, write rejection, local-member hiding, and round trips;
- clean wrong-union runtime diagnostics;
- no interface entry, external native/Lua symbol, or namespace exposure for
  members whose owning union is local.

Generated-C checks should confirm one copied tag and a dispatch-only switch
whose cases jump to labels outside the switch. For Array payload construction
and binding they must also confirm `sethvalue`/`hvalue` slot operations and the
absence of `titan_array_require_proxy`, `copyboxed`, or mixed/proxy unboxing.
Behavioral control-flow tests are decisive for dispatch, but cannot replace
this opaque representation assertion.

The new topical coder file falls into `compiler-core` under the current
catch-all. Time it on a prepared warm tree after the cases are grouped, record
the result, and explicitly choose whether it remains in core or is named in
the heavy shard. Do not let the GC/Lua/native matrix acquire an accidental CI
placement; keep the complete local `compiler` group as the union either way.

Cross-module coverage:

- source imports, including the exact §0.2 `local m = import "messages"` and
  `m.Message.move({ x = 1.0, y = 2.0 })` fixture;
- `.so`-only imports;
- `.a` static providers;
- direct and transitive owner recovery;
- multi-module prefix containers;
- public constructor/static/method/bound symbols;
- canonical imported static-closure slots and initial/unmodified Titan/Lua
  selector identity;
- public union with a hidden variant reaching importer `else`;
- preserved absolute tags after hidden variants; and
- wrong ABI rejected before Union metadata decode.

Place focused cases in:

- `spec/coder/so_import_spec.lua`;
- `spec/coder/static_compiled_modules_spec.lua`;
- `spec/coder/multi_module_libraries_spec.lua`;
- `spec/driver_spec.lua`;
- `spec/staticmetadata_spec.lua`; and
- `spec/abi_spec.lua`.

Keep bounded metadata parsing in `staticmetadata_spec`, selection/caching in
`driver_spec`, nominal constraints in checker specs, and native
construction/linking in coder specs according to the repository's test-layout
rules.

### 7.4 ABI, installer, and production

Update and extend:

- `spec/abi_spec.lua`;
- `spec/rockspec_spec.lua`;
- `spec/stdlib_installer_spec.lua`;
- `spec/libuv_build_spec.lua`;
- active stdlib/provider fixtures;
- support snapshot and production smoke scripts; and
- workflow assertions.

Prove:

- all active ABI constants agree and library paths use the derived major/minor
  release component;
- `TITAN_PATH_<major>_<minor>` selects the active compile/run dependency;
- DSO and archive mismatched ABI claims fail before type decoding;
- shared unversioned shims are replaced transactionally;
- fresh bootstrap, full pair, reinstall, failure rollback, dSYM, and shims
  retain existing guarantees;
- all nine stdlib logical interfaces serialize under the current ABI; and
- bundled/system static consumers still link against the canonical pair.

Prove that the historical canary/script is gone, its producer-preparation
responsibilities have explicit replacements, the dependency cache is ABI-keyed,
and repository instructions record the owner-approved retirement.

### 7.5 Dogfood behavior

Existing `spec/stdlib/string_regex_spec.lua` remains the main behavioral
contract. Add only cases needed to exercise a newly exposed regex-AST path;
compiler semantics belong in the focused union specs, not under LuaCov in the
library suite.

Run:

- all regex syntax/diagnostic/limit/capture/backreference cases;
- regex cache and repeated compilation;
- nullable repetition and backreference behavior;
- projected-size overflow locations through `RegexNode:position`;
- full/generational GC cases;
- the PEG/string group without LuaCov; and
- exact dynamic/static PEG/string sanitizer smokes.

## 8. Phased implementation and review sequence

### Phase 0 — recorded decisions and clean baseline

1. Treat §0.1–§0.6 as settled and copy their exact rules into the working
   branch docs/tests before implementation can drift.
2. Create a feature branch from the reviewed baseline.
3. Confirm a clean worktree and current project-local Lua 5.5/LuaRocks prefix.
4. Record baseline targeted/full test results.
5. Assign separate semantic, runtime/GC, ABI/packaging, docs, and dogfood
   reviewers.

### Phase 1 — frontend, type model, and checker

1. Enforce the compiler-manual reading gate in §4.1.
2. Before emitting or decoding any new schema, advance the compiler/runtime
   ABI marker, prepare a fresh ABI-keyed prefix/cache path, and prove that no
   Phase 1/2 test can publish Union data under a mismatched marker.
3. Add lexer/parser/contextual-FFI-name support, AST/type descriptors, and
   constructor synthesis.
4. Add checker staging, shared record/payload slot validation, visibility,
   variant-as-non-type diagnostics, option-forced case, namespace, privacy, and
   serialization logic.
5. Add lexer/parser/types/checker tests.
6. Draft `doc/language/unions.md` and `doc/implementation/unions.md` alongside
   the implementation so names and semantics cannot drift.
7. Run a semantic adversarial review before code generation begins.

Gate: parser/types/checker tests green; serialized hidden tags proven; every
new interface has the current ABI marker in an isolated prefix; no unresolved language
decision.

### Phase 2 — constructor, nominal namespace, methods, case, and GC

1. Reread the codegen/GC/interop/error-handling implementation chapters.
2. Generalize nominal metatable/namespace/import/symbol plumbing.
3. Add union metatables and constructor lowering.
4. Add all coder statement traversals.
5. Add dispatch-only-switch case lowering and ordinary binding declaration
   reuse.
6. Add direct/Lua/first-class/method/control-flow/GC tests.
7. Inspect generated C for representative payload and nested-control-flow
   cases.
8. Run independent runtime/GC and control-flow adversarial reviews.

Gate: focused coder tests green under ordinary and generational/full GC;
mandatory loop-break regression passes.

### Phase 3 — ABI, compiled providers, installer, and manuals

1. Retire the historical canary/script as decided in §0.4.
2. Replace its producer-preparation duties and ABI-key the dependency cache;
   do not merely delete the step.
3. Complete and audit the provider/installer/CI side of the ABI contract
   whose compiler/runtime constants were bumped before Phase 1 schema work.
4. Add source/DSO/archive/transitive/prefix-container tests.
5. Update installer/publication/rollback and production fixtures.
6. Complete and cross-link both manuals and all existing affected chapters.
7. Update README and `AGENTS.md`.
8. Run independent ABI/packaging and docs/example reviews.

Gate: no stale active ABI/path reference, provider/installer focused tests green,
manual examples compile.

### Phase 4 — regex dogfood

1. Enforce the dogfood language-manual reading gate in §6.1 for both
   implementer and reviewer, including the new union chapter.
2. Convert only the bounded regex AST and four dispatch families.
3. Add the stdlib source-privacy classifier support.
4. Run focused regex/PEG-string behavior and GC/sanitizer tests.
5. Reduce and centrally fix any compiler issue before continuing.
6. Run a separate Titan-language/dogfood review against the new manual.

Gate: no integer kind shadow remains; public string interface/source roster
unchanged; PEG/string behavior green.

### Phase 5 — whole-tree validation and publication

1. Run formatting/diff/stale-reference audits.
2. Run the complete local suites below.
3. Conduct final semantic, parser, checker, runtime/GC, control-flow,
   ABI/installer, docs, and dogfood adversarial passes.
4. Commit intentionally, push the exact reviewed head, and refresh/open the PR.
5. Wait for exact-head Linux CI and Codecov upload success.
6. The owner waived the full macOS dispatch for this unions-v1 branch. Record
   that explicit waiver in the final evidence rather than treating macOS as a
   failed or missing check; the repository's ordinary pre-merge policy for
   future work remains unchanged.
7. Address review/CI findings centrally and repeat exact-head evidence as
   required; do not claim an earlier head.

Warm-tree placement decision (2026-07-29): the final 13-case
`spec/coder/unions_spec.lua` completed in **5.81 seconds** on the prepared
isolated prefix. It remains in `compiler-core` through the existing catch-all.
That cost is small on the standard producer, while moving it would add native
fixture work to the 1-core, hard-15-minute heavy consumer. The complete local
`compiler` group still includes it unchanged.

Local validation evidence (2026-07-29):

- the complete 82-file compiler/language LuaCov gate passed, including its
  main, unit, and isolated-provider processes;
- `make test` performed a fresh forced rock installation and passed with
  **2507 successes, 0 failures, 0 errors, and 0 pending**;
- the bundled dynamic/static production smoke passed against the installed
  current-ABI `titan.so`/`titan.a` pair, including process and OS behavior;
- the focused provider/import matrix, installer/packaging suites,
  PEG/string behavior, and final adversarial reviews are green; and
- Lua syntax, shell syntax, workflow YAML, Markdown links, `git diff --check`,
  retired-canary, stale-active-ABI, and regex-shadow audits are clean.

The verification host does not provide a system `libuv.pc` or a separately
instrumented sanitizer prefix. The exact-head Linux producer and sanitizer
jobs therefore own the remaining system-libuv and sanitizer production
evidence. The owner-waived macOS dispatch remains intentionally unstarted.

## 9. Verification commands

Use a fresh isolated prefix and run from repository root. Busted loads
compiler Lua from the installed rock, so running it immediately against an
ordinary long-lived developer prefix can silently test stale compiler code.
Keep the serial packaging/native gates and the complete library gate ahead of
legacy compiler/coder specs: those specs may clean root-generated outputs that
the packaging checks consume. New union fixtures must remove only their exact
generated artifacts (including paired archives) and must treat the shared
runtime and canonical standard-library image as read-only.

```sh
export UNION_VERIFY_PREFIX="$(mktemp -d /tmp/titan-unions-XXXXXX)"
export PREFIX="$UNION_VERIFY_PREFIX"
export PATH="$PREFIX/bin:$PATH"
unset LUA_PATH LUA_CPATH LUA_PATH_5_5 LUA_CPATH_5_5 LUA_INIT LUA_INIT_5_5

make lua
make luarocks
"$PREFIX/bin/luarocks" make --force
"$PREFIX/bin/luarocks" test --prepare
"$PREFIX/bin/lua" -E -e \
  'assert(package.cpath:find("/lib/titan/<library-version>/?.so", 1, true), package.cpath)'

"$PREFIX/bin/busted" spec/libuv_build_spec.lua
"$PREFIX/bin/busted" spec/rockspec_spec.lua
"$PREFIX/bin/busted" spec/stdlib_installer_spec.lua

"$PREFIX/bin/busted" spec/stdlib/string_regex_spec.lua
bash spec/support/ci_test_groups.sh library-peg-string
bash spec/support/ci_test_groups.sh libraries

"$PREFIX/bin/busted" spec/lexer_spec.lua spec/parser_spec.lua spec/types_spec.lua
"$PREFIX/bin/busted" spec/checker/unions_spec.lua
"$PREFIX/bin/busted" spec/coder/unions_spec.lua

"$PREFIX/bin/busted" spec/checker/so_rehydration_spec.lua
"$PREFIX/bin/busted" spec/checker/static_compiled_modules_spec.lua
"$PREFIX/bin/busted" spec/coder/so_import_spec.lua
"$PREFIX/bin/busted" spec/coder/static_compiled_modules_spec.lua
"$PREFIX/bin/busted" spec/coder/multi_module_libraries_spec.lua
"$PREFIX/bin/busted" spec/driver_spec.lua spec/staticmetadata_spec.lua spec/abi_spec.lua

bash spec/support/ci_test_groups.sh compiler
make test
```

After any compiler-Lua change made between targeted checkpoints, rerun
`"$PREFIX/bin/luarocks" make --force` before invoking Busted again.
Give concurrent agents separate `mktemp` prefixes. Never cite a targeted result
from a prefix whose installed compiler does not match the tested worktree.

Run the bundled/system production smokes and
`spec/support/ci_peg_string_sanitizer_smoke.sh` in their documented prepared
environments. Do not run the PEG/string behavior suite under LuaCov.

Final static checks:

```sh
git diff --check
rg --hidden -n -g '!.git/**' 'TITAN_|lib/titan/' .
rg -n 'REGEX_(EMPTY|LITERAL|ANY|CLASS|SEQUENCE|CHOICE|GROUP|REPEAT|BACKREFERENCE|WORD_START|WORD_END)|node\.kind' \
  titan/string/regex_parser.titan titan/string/regex_compile.titan
```

Classify every hit against the split ABI/release/library contract.

## 10. Completion criteria

The feature is done only when:

1. every case arm uses `when`, all three new keywords remain prefix-safe, and
   raw keyword spellings are admitted only through the metadata-backed `CNAME`
   FFI gate (including `when`, `repeat`, and `type` coverage);
2. unions have at least one variant, empty variants reject binders, cases remain
   non-exhaustive, and the rest of the recorded owner decisions in §0 are
   reflected consistently;
3. `Type.Variant` occurs only as validated union-owned metadata—never in a
   value-facing/recovered type graph—and local/imported variant-looking RHS
   forms for both `as` and `is` fail through their specified semantic/parser
   paths while the owning union type remains legal;
4. imported unions match the exact current record frontier: later imports work
   in aliases/fields/payloads/signatures/ordinary bodies, direct module-variable
   and nested-lambda uses remain ordered, and the alias bridge remains legal;
5. synthesized constructors publish `paramnames = false`, behave as ordinary
   static functions across direct, Lua, first-class, source/DSO/archive import
   paths, and compile the exact §0.2 `import`/`float`/parenthesized-record
   example while rejecting named-call syntax;
6. only validated record/variant constructors with constant arguments receive
   module-constant treatment; a nonconstant argument or ordinary
   owner-returning static does not;
7. local variants preserve absolute tags without leaking names/payload types;
8. case forces `Union?` through the ordinary option path, evaluates once on
   present and nil paths, resolves arms only in the scrutinee's exact union,
   cannot fall through, preserves enclosing-loop break, uses the exact
   `if`-block catch/finally/defer/return rules, and preserves ordinary binder
   capture/root/spill behavior;
9. one shared `types.has_tvalue_representation` checker rule governs record
   fields and union payloads, including the audited/documented C-array and
   function-pointer compatibility tightening and exact `TValue` exception;
10. Udata allocation, record-identical internal payload slots (including
    generated-C proof of raw Array backing storage), exact C exceptional forms,
    roots, and barriers survive full and generational GC;
11. union values remain immutable/opaque at Titan and Lua boundaries while
    reference payload mutation aliases correctly;
12. source, DSO, archive, transitive, and multi-module provider behavior agrees;
13. the ABI is bumped before any new schema/layout test, every active ABI
    marker agrees, the search/install path uses the active library version, and mismatched
    providers are rejected;
14. both new manual chapters and every affected existing chapter are updated;
15. regex dogfooding uses the documented language feature with no shadow kind
    or public API/roster change;
16. targeted, complete, production, sanitizer, and exact-head Linux gates are
    green, and the owner-waived macOS dispatch is recorded; and
17. final adversarial reviews find no semantic, GC, control-flow, interface,
    installer, documentation, or dogfood gap.
