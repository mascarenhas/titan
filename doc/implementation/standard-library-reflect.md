# Reflection library implementation

The public API is documented in the
[reflection standard-library chapter](../language/standard-library-reflect.md).
`titan.reflect` is a flat Titan standard module using the pinned Lua 5.5
runtime. The compiler emits its discoverable metadata in ordinary nominal
metatables and callable closures.

`Value` stores pure container, callable, thread, and owned-storage metadata as
named union parts. `RecordValue`, `InterfaceValue`, and `UnionValue` remain
records because they own typed accessor methods. `Type` similarly stores pure
Array, Map, and scalar/pointer C metadata as named parts. Nominal descriptors
shared by `NominalType`, callable/owned descriptors reused in `Value`, resolver
owners, and retained recursive C aggregates remain records. The retained
object or callable is named `value`; a corresponding descriptor is `type`.

## Metadata ownership

The per-state registry table at `TITAN_METATABLES_KEY` maps fully qualified
nominal names to their canonical metatables. Reflection obtains this table
during module initialization; lookup does not load additional modules.

The relevant metatable entries use private lightuserdata keys:

| Key | Value |
| --- | --- |
| `TITAN_BRAND` | Runtime kind: Array, const Array, record, union, Interface, or owned C storage |
| `TITAN_MT_TYPE` | Compiler-generated `types.serialize(...)` expression for the schema |
| `TITAN_MT_MEMBERMAP` | Public field accessor addresses and public method closures, keyed by name |
| `TITAN_MT_STATICS` | Constructor and static-function closures, keyed by their member names |
| `TITAN_MT_MOD` | Declaring module userdata for record and Interface accessors |
| `TITAN_MT_PAYLOAD` | Generated typed payload reader for a union |

Record and Interface field entries in the member map are lightuserdata
addresses of generated native accessors. Method entries remain Lua-callable C
closures. Union member maps contain methods only. The module owner is read
directly from `TITAN_MT_MOD`, independently of the `__index` closure's upvalue
layout.

Nominal `TITAN_MT_TYPE` tags serialize the declared type, preserving generic
binders and parameters for reflection hydration. Generated accessors still
use the erased runtime type, and callable identity tags and compiled-provider
export metadata retain their existing representations. Every specialization
continues to share its declaration's runtime nominal identity.

`types.serialize` omits local members. Public record fields retain their
original logical indices, including gaps left by private fields. Public union
variants retain their runtime tags, which form a dense zero-based public range;
private variants follow that range regardless of interleaved source declarations.
Hydration preserves a dense Array of visible descriptors. Record field ordinals
are distinct from logical field indices, and private active union tags have no
public descriptor.

## Descriptor hydration

`hydrate_type` evaluates the compiler-produced descriptor expression through
`titan.lua.load` with an explicit constructor environment. This is an internal
decoder for trusted compiler metadata, not a public source-evaluation API.
Its constructors match serializer spellings such as `Record`, `Field`,
`Function`, `Nominal`, and `COwned`.

The active nominal metatable supplies its member map, statics, and module
owner. For a record or Interface, a `Field` constructor caches the typed
native accessor and a traced module value in private const fields of
`FieldType`. Union parts use serialized `Field` metadata too, but have no
field accessor; hydration must not treat a same-named union method as one.
The `Variant` constructor projects the ordered fields into `VariantPartType`
records containing only name and type, then publishes `VariantType.parts`. A `Method`,
`StaticMethod`, or `Variant` constructor resolves its callable from the owning
member/static table. Fields and variants retain declaration order; record and
union method/static maps become sorted Arrays. Interface methods arrive as a
positional list and retain that order.

The hydration context is saved and restored around each operation, including
failure, so nested work cannot replace its caller's active owner tables.
Completed descriptors are cached by metatable. Successful nominal lookups are
also cached by qualified name.

### Generic erasure and named boundaries

Generic binder/scope metadata does not introduce another public descriptor
family. `Parameter` yields `Type.is_value()` when unconstrained and the
serialized erased constraint when constrained. That constraint is the outer
nominal Interface reference, represented by `Type.is_named`; it is not
resolved while hydrating the parameter. `FunctionScheme` yields its erased
function signature. Nominal application arguments do not create separate
runtime descriptor identities.

This retains structural Array, Map, and callable shapes while erasing their
parameter leaves. Option hydration collapses a `value` base to `is_value` and
nested Options to one Option, matching the runtime carrier; other Option bases
retain their descriptor. `NamedType:resolve()` performs a later nominal
registry lookup. It does not recursively expand the descriptor graph.

### Recursive C declarations

The serializer uses `CNamed` to refer back to a C struct, union, or typedef
already encountered in the current declaration graph. Hydration represents
that reference as `Type.is_foreign_named(ForeignNamedType)` and records each
completed C declaration in a per-hydration table. A `ForeignNamedType` retains
that table privately alongside its public qualified `name`, so later
inspection or collection cannot replace the reference's resolution context.

`ForeignNamedType:resolve()` looks up one retained declaration and raises
`unknown foreign type <name>` if absent. It does not recursively follow the
result's pointer, aggregate, or typedef members. `Type:resolve()` delegates
for `is_named` and `is_foreign_named` receivers and otherwise returns its
receiver. C backreferences are a separate serializer mechanism from generic
erasure: they do not eagerly resolve generic constraints or restore erased
type arguments.

## Generated field accessors

Each public record or Interface field has one native accessor. Its common
protocol returns void and accepts the current Lua state, declaring module
userdata, receiver userdata, a pointer to one `TValue` input/output slot, and
a read/write flag. The pointer is stored in the member map as lightuserdata
and recovered as the exact foreign function-pointer type during hydration.

The generated body knows the field's type and physical slot:

- A read uses the compiler's normal boxing operation, including fields whose
  storage omits a complete boxed tag.
- A write to a mutable record field completes its checker-owned dynamic
  boundary conversion before mutation, then applies the Lua GC write barrier
  only if the selected slot is traced.
- A const record field or Interface field rejects the write mode.

Ordinary Lua member access and reflection use the same generated field
conversion behavior. Reflection selects a cached `FieldType` by public
descriptor ordinal and calls its accessor directly; it does not repeat a
name lookup, invoke `__index`/`__newindex`, or write raw payload bits as if
every field were a `TValue`.

`RecordValue:get` and `set` validate `1 <= i <= n_fields`; the generated
accessor enforces constness on writes. `InterfaceValue:get` applies the
same ordinal/bounds rules to captured fields. The corresponding `.value` keeps
the receiver reachable; the private module value in `FieldType` keeps the
declaring owner reachable. A local `TValue` supplies the accessor's input or
output and the module value is unboxed only for the native call.

Conversion may allocate, particularly when constructing an Interface wrapper.
Keep source and destination roots valid across those conversions, publish
boxed output promptly, and do not retain a movable Lua stack pointer across
an allocating call. A failed conversion must leave the old field intact.

## Value classification

`inspect` dispatches on the Lua tag, then on a recognized userdata brand or
function representation. Numeric classification checks the actual integer
tag; a written `value is integer` test would also accept integral floats and
would lose that distinction.

Mutable and const Arrays expose their erased container views; Lua tables
become Map values. Unbranded or unrecognized full userdata remains an opaque
`Value.is_lua_userdata` variant. Lightuserdata becomes `is_raw_pointer`, and Lua threads
retain both their traced value and raw state address.

### Union payloads

Each generated union publishes a typed reader at `TITAN_MT_PAYLOAD`, cached
in a private const field of `UnionType`. Its void-returning protocol accepts
the Lua state, union userdata, a `lua_Integer` selector, and a `TValue` output
pointer. Selector 0 returns the native tag; -1 returns the active variant's
logical arity; positive selectors read 1-based parts. The generated tag/part
switch boxes from the physical plan, including native numeric checks and
borrowed aggregate/array addresses. An invalid selector yields nil.

The switch covers private as well as public variants because either can occur
in a runtime value. The semantic descriptor still omits private names and
schemas. `UnionValue` retains the original value, borrowed userdata address,
reported tag, and logical `n_parts`; `get(i)` checks its ordinal bounds before
calling the reader. A nil part still counts, independently of whether it has a
traced slot. Reflection never derives tag or arity from UV count. See
[Native nominal storage](nominal-storage.md).

### Interface receivers

An Interface wrapper retains its concrete receiver in user value 1. Its
captured fields begin at user value 2. Field access uses generated accessors
to box those snapshots correctly; `.wrapped` exposes the concrete receiver
as a value, while `.value` remains the Interface method receiver.

## Function inspection

A Titan function is a branded C closure. Its descriptor string is carried in
upvalue 1, the native entry address in upvalue 2, and `TITAN_BRAND` in upvalue
3. `cl->f` is the Lua C entry. Hydration produces a `FunctionType`; a generic
function's descriptor is interpreted through the same erasure rules.

Lua bytecode closures are inspected with `lua_getinfo(L, ">Su", ...)` for
source, line, and parameter information. Keep the temporary stack transaction
balanced on success and error and copy surviving values into traced Titan
state. Ordinary C closures and light C functions both produce
`Value.is_lua_c_function`.

The public `lua_entry`/`entry` parts are typed foreign Lua C function
pointers. `native_entry` is an untyped address. The retained `value` callable part
is the ordinary application invocation path.

## Owned C storage

The `TITAN_OWNED` brand selects an owned pointer or counted Array descriptor.
The value variant exposes `getudatamem(u)` as its payload address and `u->len` as
the storage size. Counted Arrays also carry their element count in user value
0. A traced `value` part retains the storage owner; its raw payload pointer alone
does not root it or acquire any external resource lifetime.

## Verification boundaries

Public classification, descriptors, member dispatch, field conversion,
visibility, and GC lifetime belong in the native tests under
`spec/stdlib/titan/reflect/`. Exercise a fresh collectable value after its
maker returns, and use minor collections against an aged receiver when
checking a write barrier; a local constant string plus a full collection is
not a barrier oracle.

Generated accessor shape, compiler boundary-plan selection, metadata
publication, and ABI compatibility belong in the existing compiler/packaging
Busted layers. Keep those implementation assertions out of the native public
API suite.
