# Titan C FFI redesign - preliminary design and implementation plan

Status: preliminary design, informed by multi-agent codebase research and local
experiments. This is not an implementation patch.

## Objective

Redesign Titan's C FFI so Titan can interact with real C libraries without
manual bridge C, while preserving the main advantage of the current FFI: a
`foreign import "header.h"` turns C declarations into direct generated C calls.

Required outcomes from the prompt:

1. No manual bridge C for ordinary C library use. Header import remains unless a
   replacement is clearly better.
2. Calls from Titan to C should be as close to zero-cost as possible.
3. Titan functions should be passable to C function-pointer callbacks, through
   generated thunks where needed.
4. Titan-allocated C storage should be tracked by Lua/Titan GC, using `Udata`,
   and must stay anchored when unwrapped for C calls.
5. C struct and union fields should use normal Titan field syntax.
6. C interop is unsafe; Lua gradual-typing guarantees do not extend across it.
7. FFI values that reach Lua may be opaque lightuserdata or userdata.

## Research workflow

Three explorer tracks were launched:

- Current FFI pipeline, type model, and migration risks.
- C structs/unions/pointers, owned allocation, and field access syntax.
- Function pointers/callbacks and Titan first-class function representation.

The tracks agreed on the main direction: keep `foreign import`, promote ad-hoc
C types into official internal type tags, keep `p.x` field syntax, separate C
field lvalues from Titan record fields, use full userdata for owned C
allocation, and model C function pointers separately from Titan
`Type.Function`.

## Evidence map

- Roadmap: `README.md` lists "FFI with C, continued (other C primitive types,
  C arrays, C structs/unions including pointers, function pointers)" as next.
- Current language behavior: `doc/language/ffi.md` documents direct header
  import, direct calls, opaque pointers, and current limitations.
- Current implementation: `doc/implementation/ffi-internals.md` documents the
  compile-time C toolchain, `Type.ForeignModule`, ad-hoc `Type.Pointer` and
  `Type.Typedef`, direct `codeforeigncall`, and field stubs.
- Parser: `titan-compiler/parser.lua` already lowers `e.name` to `Ast.VarDot`,
  so C field access does not need new surface syntax.
- Checker: `titan-compiler/checker.lua` resolves `VarDot` only for Titan
  modules, foreign modules, record statics, and Titan record fields. Pointer to
  C composite field access is absent.
- C type conversion: `titan-compiler/foreigntypes.lua` returns stub `Struct` and
  `Union` tables and does not convert their fields.
- Codegen: `titan-compiler/coder.lua` emits foreign calls as bare C calls and
  pointer locals as bare C pointers. Titan records use `Udata` user-value slots;
  C fields need a separate lvalue path.
- GC discipline: `doc/implementation/values-and-gc.md` makes "caller anchors"
  and userdata back-barriers explicit. Owned C objects should reuse that shape.
- First-class functions: `coder.lua` represents a Titan function value as a
  boxed `TValue`; exact Titan closures have `CClosure` upvalues
  `[0]=_mod`, `[1]=type tag`, `[2]=native entry`, `[3...]=captures`.
- Native Titan entries have Titan's ABI
  `RETTYPE f(lua_State *L, Udata *_mod, CClosure *_fn, ...)`, not the C
  callback ABI. Any callback thunk that wants closures or bound methods to work
  must retain and pass the actual callee `CClosure *` as `_fn`; a native pointer
  alone is not enough.

## Local experiments

Experiment source: `.claude/plans/c-ffi-redesign-experiments/ffi_probe.c`

Build command:

```sh
cc -I lua-5.5.0/src -Wall -Wextra -Werror \
  -o /tmp/titan_ffi_probe \
  .claude/plans/c-ffi-redesign-experiments/ffi_probe.c \
  lua-5.5.0/src/liblua.a -lm -ldl
```

Run output:

```text
layout:size=32 x=0 y=8 u=16 union.double=8
owned-inline:x0=7 y0=3.5 u0=11 x1=13 len_count=2 uv_count=2 tagged=yes anchored=yes
owned-after-gc:no-finalizer-needed
callback-sum=20
```

What this validates:

- Struct layout must be left to the C compiler. The probe struct has padding
  before `double y`; Titan should emit C field expressions and `sizeof(T)`
  rather than try to reproduce ABI layout in Lua.
- A full Lua userdata can store the C object bytes inline, recover the element
  count from `Udata.len`, and use user values for metadata such as a C type tag
  and cached count. No finalizer is needed for Titan-owned inline storage.
- A C callback of shape `int (*)(int, void *)` can adapt through a thunk and
  context pointer into a Lua/Titan callable value. This is the low-risk callback
  case and should be implemented first.

## Design summary

Keep the current high-level model:

```lua
local C = foreign import "some/header.h"
C.some_function(...)
```

But replace the current "mostly Titan types plus ad-hoc pointer tables" model
with an explicit C type layer inside the compiler. The checker can then know
when an expression is a C value, a borrowed C pointer, an owned C pointer, a C
struct/union type namespace, a C function pointer, or a Titan value being
converted for C.

The generated C should stay simple:

- C calls remain direct calls to the C identifier.
- C field reads/writes become `ptr->field` or `value.field`.
- C allocation uses `sizeof(C_TYPE)` in generated C, not a Lua-computed layout.
- Owned C storage is a Lua full userdata whose raw payload stores the pointer,
  C object bytes. User values carry metadata such as a type tag and, when useful,
  a cached element count.
- Passing an owned object to C computes the raw payload pointer with
  `getudatamem` and keeps the userdata anchored for the call.

## Surface language

### Header import stays

Keep:

```lua
local SDL = foreign import "SDL2/SDL.h"
```

This remains the ergonomic center of the FFI. The current approach is already
LuaJIT-FFI-like in the useful way: users name headers, not hand-written glue.

### Header resolution and generated includes

The current prototype has a split-brain rule: `c-parser/cpp.lua` resolves the
top-level `foreign import` header for parsing, but `coder.lua` later chooses the
generated `#include` spelling only from the original string:

```lua
if node.headername:match("^/") then
    include = [[#include "$HEADERNAME"]]
else
    include = [[#include <$HEADERNAME>]]
end
```

The checker does not currently rewrite `node.headername` to the resolved path.
For a non-absolute top-level import, `cpp.parse_file` searches system include
directories first, then may fall back to opening the original relative name from
the current working directory. The generated C still includes the original
relative name with angle brackets, so a header that the Lua-side parser happened
to find locally can fail later in the C compiler.

V1 should make header resolution an explicit product of the foreign-import
pipeline. `cdriver.process_file` should return both the parsed declarations and
an include descriptor:

```lua
{
    original = "local_probe.h",
    resolved = "/path/to/module/local_probe.h",
    include_kind = "quote", -- or "angle"
    include_name = "local_probe.h",
}
```

Recommended top-level lookup:

1. If the import string is absolute, read that path and generate
   `#include "/absolute/path.h"`.
2. Otherwise, try C's quoted include rule relative to the Titan module source
   directory. Generated `.c` files live next to the `.titan` source, so if
   `foreign import "ffi/local_probe.h"` resolves there, emit
   `#include "ffi/local_probe.h"`.
3. If that fails, search system include directories and emit
   `#include <original-name>`.

This aligns parse-time and C-compile-time behavior without requiring generated
C to know the Lua preprocessor's private resolved path. If later `titanc` grows
explicit `-I` support, those include directories should be part of this same
descriptor and passed to both the Lua preprocessor and the C compiler.

### C type namespaces

Imported named C composites and typedefs should appear as module members in a
type-namespace role:

```lua
local H = foreign import "/tmp/probe.h"

local p = H.ProbePoint.new()
p.x = 10
p.y = 4.5
H.consume_point(p)
```

`H.ProbePoint` is not a Titan record and not an ordinary first-class value. It
is a foreign type namespace, similar in spirit to a record static namespace:

- `H.ProbePoint.new()` returns a GC-owned `struct ProbePoint`, zeroed in the
  userdata payload.
- `H.ProbePoint.new_array(n)` returns a GC-owned array of `n` inline elements.
- `H.ProbePoint.sizeof` and `H.ProbePoint.alignof` can be constants once layout
  probing exists.
- Later, `H.ProbePoint.wrap(ptr)` can create a borrowed view and
  `adopt(ptr, finalizer)` can explicitly take ownership of C pointers returned
  by libraries. Adoption is a separate mode from Titan-owned inline allocation.

The exact method names can change, but the important point is that allocation is
available from the imported header namespace without manual bridge C.

### C types in Titan annotations

V1 should lift a prototype limitation: imported C FFI types must be usable in
Titan type annotations, not only inferred from foreign calls. The existing
parser already has `Ast.TypeQualName` for `module.Type`; the checker should
extend that rule so a qualified type name may resolve through a foreign module
as well as a Titan module.

Examples:

```lua
local H = foreign import "/tmp/probe.h"

local function bump(p: H.ProbePoint): nil
    p.x = p.x + 1
end

local cmp: H.CompareCallback = H.CompareCallback.new(function (a: integer, b: integer): integer
    return a - b
end)
```

The exact names exposed by a foreign module are part of the C type namespace:
`H.ProbePoint` might denote the default owned inline representation for
`struct ProbePoint`, while a typedef'd callback or pointer type should preserve
the imported C typedef name. If v1 needs annotations that cannot be expressed as
today's single `NAME.DOT.NAME` grammar, it should either add explicit syntax or
expose additional type-namespace members rather than falling back to inference
only.

Checker work:

- `Ast.TypeQualName` should accept a receiver whose type is
  `Type.ForeignModule`/`Type.CModule`.
- The foreign module needs a type namespace distinct from callable/value
  members, so `H.printf` is not accidentally accepted as a type.
- A missing or non-type member should produce a normal type-resolution error.
- This is allowed for locals, local functions, lambdas, private helper
  signatures, and other module-internal annotations.
- Public exported interfaces are still rejected by the cross-module policy
  below.

### Field access

Use ordinary Titan field syntax:

```lua
p.x
p.u.as_int
p.x = 42
```

The parser already produces `Ast.VarDot`; the checker chooses the meaning from
the receiver type:

- Titan record value: existing `Udata` user-value field access.
- C borrowed pointer to struct/union: generated C `ptr->field`.
- C owned pointer to struct/union: unwrap userdata, check the type tag, compute
  the raw payload pointer, then generated C `ptr->field`.
- C struct/union by value, if added later: generated C `value.field`.

Union access is intentionally unsafe and C-like. Titan does not track the active
union variant.

### C arrays and indexing

Do not block struct/union field access on full C array support. Phase 1 should
parse array fields enough to reject or pass them opaquely. Phase 2 should add C
array indexing and pointer arithmetic explicitly.

Open language question for phase 2: whether C indexing should use Titan's
ordinary bracket syntax with C's zero-based indexing, or a visibly foreign
operation. The design should not quietly make C arrays look like Titan arrays
with different indexing rules.

### Function pointers and callbacks

Imported C function-pointer types should become C function pointer types, not
ordinary Titan function types. `Type.Function` means a boxed Titan/Lua callable;
`Type.CFunction` means a raw C ABI signature. A Titan function value can be
adapted where a C function pointer is expected only when the C signature is
representable.

Recommended callback surface:

```lua
local cb = C.CallbackType.new(function (x: integer): integer
    return x * 2
end)

C.register_callback(cb)
```

For APIs that take both a function pointer and a `void *userdata`, allow a more
ergonomic direct call:

```lua
C.foreach(values, function (x: integer): integer
    return x * 2
end)
```

The checker recognizes a function-pointer parameter paired with a user-data
context parameter and codegen materializes both the thunk pointer and context
pointer. This is the first callback form to implement.

For APIs that store callbacks after the registering call returns, users must
keep the callback object alive. A call-site temporary is only valid for
synchronous callbacks that happen during the C call.

Phase 1 callback restrictions should be explicit: exact Titan `CClosure` values
only, non-variadic callbacks, one C return value, supported scalar/pointer
parameters, same `lua_State`, no yielding, and no implicit `string` return unless
ownership has been specified.

## Internal type model

Move C types into `types.lua` instead of continuing ad-hoc tables. Suggested
tags:

- `Type.CVoid`
- `Type.CInteger { spelling, signed, rank, bits? }`
- `Type.CFloat { spelling }`
- `Type.CPointer { pointee, quals }`
- `Type.CArray { elem, len }`
- `Type.CFunction { params, ret, vararg, abi }`
- `Type.CStruct { cname, tagname, typedef, fields, complete }`
- `Type.CUnion { cname, tagname, typedef, fields, complete }`
- `Type.CField { owner, name, type, bitfield? }`
- `Type.CTypedef { name, target }`
- `Type.COwned { pointee, count? }`
- `Type.CAdopted { pointee, finalizer, count? }` if explicit adoption of
  externally allocated memory is added.
- `Type.CModule` or keep `Type.ForeignModule` with richer members.

This requires updating:

- `types.equals`
- `types.compatible`
- `types.coerceable`
- `types.explicitly_coerceable`
- `types.tostring`
- `types.serialize` should not need C-type cases in v1, because public Titan
  module interfaces cannot mention C types.
- `types.is_gc` for `Type.COwned` and callback objects
- checker visitors and coder type dispatches

### Cross-module policy

V1 should keep all C types local to the Titan module that performs the
`foreign import`. A public Titan module interface must not mention `Type.C*` in
exported function parameters/returns, exported variables, record fields, record
statics, or methods. Reject these with a clear diagnostic such as:

```text
cannot export C FFI type 'struct ProbePoint *' from Titan module 'm';
C FFI types are local to modules that import their headers
```

This is stricter than "serialization not implemented yet" on purpose. A module
that imports a compiled Titan `.so` and rehydrates its interface would also need
its generated C source to include the same C header(s) before it could name or
pass those C types in generated C. That include/provenance problem is not solved
by serializing the C type graph. So v1 has no cross-module C type ABI and should
not bump `TITAN_VER` for C type export.

Future support would need both pieces: type serialization/identity and generated
C include propagation or explicit re-import requirements in every consuming
module.

This export ban must be enforced after the checker has resolved annotations.
Do not preserve the prototype's old behavior where `Ast.TypeQualName` simply
failed for foreign modules. Instead, allow the annotation first, then reject it
only if it appears in an exported position. In today's language records are
public, so record fields plus method/static parameter and return types are
exported positions.

## C declaration processing

The current pure-Lua preprocessor and C99 parser can continue as the front end,
but the redesigned FFI should not try to compute target ABI layout in Lua.

Recommended hybrid:

1. Use `c-parser/` to discover declarations, typedefs, fields, function pointer
   types, array extents, enum names, and macro constants.
2. Normalize these into the official `Type.C*` model.
3. Generate C expressions using the original C spelling under the imported
   headers.
4. Use the host C compiler as the layout oracle for `sizeof`, `alignof`,
   `offsetof`, enum numeric values, and validation where Titan needs constants.

For direct generated C like `p->field`, no runtime offset calculation is needed;
the C compiler handles padding and ABI layout. Layout probing is mainly needed
for user-visible `sizeof`/`alignof`, owned array allocation metadata, enum
values, diagnostics, and future generic operations.

## Checker behavior

### Calls

C calls stay statically checked. For each C parameter:

- If the Titan expression is already a compatible C type, pass it directly.
- If it is a Titan scalar/string/nil accepted by the C type, insert an
  `ExpCast` or a dedicated C-boundary coercion node.
- If it is an owned C object passed to a borrowed pointer parameter, unwrap it
  and mark the owned object as anchored across the call.
- If it is a Titan function passed to a C function pointer parameter, require a
  supported callback adaptation.

The coder must materialize side-effecting operands once before using them in
generated C expressions, following the existing codegen rule for binary ops.

### C casts and conversions

Use three distinct notions:

- **C assignment conversion:** implicit only in C contexts, such as an argument
  to a foreign call, assignment to a C field, C callback return, or initializing
  a C temporary.
- **Titan `as` cast:** explicit in source and allowed for unsafe reinterpretation
  or lossy conversion.
- **`value` boxing/unboxing:** explicit at the C boundary except for values that
  already are Lua GC objects, such as owned C userdata and callback userdata.

#### C-to-C conversions

Implicit in C contexts:

- Exact type after typedef resolution.
- Qualifier addition, such as `T *` to `const T *`.
- Object pointer to `void *`, preserving qualifiers.
- `nil` to any C pointer or C function pointer.
- `Type.COwned(T)` or `Type.CAdopted(T)` to borrowed `T *` or `void *`, by
  unwrapping while keeping the userdata anchored for the call.
- C array lvalue to pointer to first element, in C rvalue/call contexts.
- C function designator to C function pointer.
- C numeric assignment conversions among C integer/float types. This follows C's
  unsafe truncation/wrapping rules; codegen should emit an explicit C cast when
  useful to make the generated intent clear and quiet warnings.

Explicit with `as`:

- `void *` to `T *`.
- Pointer between unrelated non-void pointee types.
- Dropping qualifiers, such as `const T *` to `T *`.
- Integer/pointer casts (`uintptr_t`-style) if the relevant C integer type is
  representable.
- C function pointer casts between different signatures. These are unsafe and
  should be rare; v1 may reject them until the thunk story is stable.

Rejected in v1:

- Struct/union by-value casts that require layout copying between unrelated
  composites.
- Casts involving incomplete struct/union types except pointer-to-pointer casts.
- Bitfield lvalues as addressable values.

#### Titan-to-C conversions

Implicit in C contexts:

- Titan `integer` to any C integer type.
- Titan `integer` to C floating types.
- Titan `float` to C floating types.
- Titan `boolean` to C `_Bool`/`bool`, and to C integer types when the C
  declaration asks for an integer flag.
- Titan `nil` to any C pointer or C function pointer.
- Titan `string` to `const char *` for the duration of a call, zero-copy. The
  caller's ordinary GC anchoring keeps the `TString` alive during the call.
- Titan function value to a supported `Type.CFunction` callback parameter only
  through generated thunk materialization; it is not a raw function pointer.

Explicit with `as`:

- Titan `float` to C integer types.
- Titan `string` to mutable `char *`. This remains unsafe because Titan strings
  are immutable and C must not write or retain the pointer.
- Titan `value` to a C type, using the unboxing rules below.

Rejected in v1:

- Storing a Titan string into a C struct field of type `char *` or `const char *`
  unless an explicit owned-copy helper is used.
- Passing a Titan array/map/record directly to C except through an explicit
  pointer/owned wrapper operation.

#### C-to-Titan conversions

Implicit when a C result is consumed in a Titan-typed context:

- C integer types to Titan `integer`.
- C floating types to Titan `float`.
- C `_Bool`/`bool` to Titan `boolean`.
- `char *`/`const char *` to Titan `string` by copying, with a null check.
- C pointer to `nil` compatibility for equality/null tests and pointer
  truthiness in conditions.

Explicit with `as`:

- C numeric to a narrower/different Titan numeric type when the implicit context
  would not choose it.
- C pointer to Titan `string` by treating the pointer as a NUL-terminated
  `char *`; this preserves the current `void* as string` idiom.
- C pointer or C function pointer to `value`, which boxes an opaque FFI handle
  rather than exposing the raw pointer as a typed Titan value.
- C scalar to `value`, by first converting to the corresponding Titan scalar and
  then boxing.

Rejected in v1:

- C struct/union by value to a Titan record. They are unrelated representations.
- C pointer to Titan record/array/map/function without an explicit wrapper.

#### `value` interop

`value` is the Lua/Titan dynamic box (`TValue`), not a magic C dynamic type.
Rules:

- `Type.COwned` and callback objects are already full userdata, so converting
  them to `value` can hand out the same userdata object. Lua sees an opaque
  userdata.
- Borrowed C pointers converted to `value` should be boxed in an opaque FFI
  handle userdata carrying the pointer, C type tag, and ownership mode. Avoid
  using bare lightuserdata for typed handles because it cannot reliably preserve
  type identity for later casts.
- A future deliberately-unsafe escape hatch may expose `void *` as lightuserdata,
  but that should not be the default typed path.
- `value as CPointer(T)` is allowed only when the value is `nil` or an FFI handle
  userdata with a compatible C type tag. Arbitrary Lua userdata is not accepted.
- `value as void *` may accept an FFI handle and, if explicitly marked unsafe,
  lightuserdata.
- `value as COwned(T)` is allowed only for an owned FFI handle of the exact type;
  borrowed pointer handles do not become owned.
- `value as CInteger/CFloat/CBool` follows the existing Lua-boundary numeric and
  boolean checks, then applies the C conversion.
- `value as string` remains the ordinary Titan dynamic cast to Titan string; it
  is not a C `char *` borrow unless followed by a C-context conversion.

### Fields

Extend `Ast.VarDot` checking:

- `CPointer(CStruct/CUnion)` and `COwned(CStruct/CUnion)` resolve fields from
  the composite type metadata and annotate the node with a C field descriptor.
- Assignment to a C field is allowed when the target C field type accepts the
  Titan source expression.
- Field reads convert back to Titan only when the C type has a Titan value
  representation. Otherwise the result remains a C type that can flow into other
  C calls.

Do not reuse `Type.Field`: it is record-specific and means "slot in a Titan
record userdata". C fields are C lvalues.

### Strings

Keep the current zero-copy `string -> char *` conversion for call arguments, but
be stricter for storage:

- Passing a Titan string to `const char *` for a call is okay and zero-copy.
- Storing a Titan string into a `char *` field should be rejected in phase 1,
  because the C struct could outlive the Titan string buffer.
- Reading a `char *` field can copy into a Titan string, with a null check, or
  remain a borrowed `char *` depending on context.
- Add explicit owned C-string helpers later if this becomes common.

### Unsupported C

Change silent skipping into structured diagnostics where possible. It is fine to
skip declarations that use unsupported C constructs, but the imported module
should remember skipped names and why, so `C.foo` can report:

```text
member 'foo' was declared in header.h but is unsupported: function pointer return type ...
```

That is better than today's indistinguishable "member not found".

## Code generation

### Direct C calls

Keep the current winning property:

```c
result = c_function(arg1, arg2);
```

There should be no generic runtime dispatcher for ordinary C calls.

### C lvalues

Add a C-lvalue codegen path separate from Titan record variables:

- `codecvalue(ctx, exp)` returns setup statements and a C rvalue.
- `codec_lvalue(ctx, var)` returns setup statements, C lvalue text, and C type.
- `codeforeignexp` uses C rvalues for C-to-C argument passing.
- `foreigntonativeexp` converts C results when Titan needs a Titan value.
- `nativetoforeignexp` converts Titan values when C needs a C value.

Examples:

```c
_owned = titan_ffi_checkowned(...);
_ptr = (struct ProbePoint *)getudatamem(_owned);
_ptr->x = (int)_local_x;
_tmp = _borrowed->field;
```

### Owned C objects

For objects whose lifetime is owned by Titan, the C object lives directly inside
the userdata raw payload. This is the default owned representation:

```c
Udata *_box = luaS_newudata(L, sizeof(struct ProbePoint) * count, 2);
setuvalue(L, _slot, _box);                 /* anchor before later allocation */
setpvalue(&_box->uv[0].uv, probe_point_tag);
setivalue(&_box->uv[1].uv, (lua_Integer)count);
struct ProbePoint *ptr = (struct ProbePoint *)getudatamem(_box);
```

`Udata.len` already records the raw payload byte length, so `count` can be
reconstructed as `_box->len / sizeof(struct ProbePoint)`. Keeping `count` in a
second user value is still useful when generated code wants the value without
repeating the division, or when future owned slices expose a logical length that
differs from capacity.

The type tag can live in `uv[0]`, as a metatable pointer, or both. The important
property is that a `Type.COwned` value is a GC value and must be anchored like a
record before any subsequent allocation. Passing it to C unwraps
`getudatamem(_box)`; the stack slot keeps the userdata and its payload alive
across the call.

No `__gc` finalizer is needed for this default case: Lua frees the userdata
payload. A finalizer-bearing wrapper is only for explicit adoption of external
C allocations returned by libraries, where the raw payload stores a pointer plus
the library-specific release function. Borrowed pointers remain bare C pointers
and are not GC tracked.

### Callback objects

Represent long-lived callbacks as userdata:

```c
typedef struct TitanCCallback {
    lua_State *L;
    int registry_ref;
    CClosure *callee;
    const void *signature_tag;
    int slot;
    unsigned char alive;
} TitanCCallback;
```

The userdata roots the Titan function value, keeps the exact `CClosure *` needed
by the native fast path and by closure captures, and releases any trampoline slot
from `__gc`.

Implementation tiers:

1. Context-pointer callbacks. If the C API accepts `fn, void *ctx`, generate one
   static thunk per C signature and pass the callback userdata as `ctx`. This is
   robust and was validated by `ffi_probe.c`.
2. Synchronous call-site callbacks. If the C API calls the callback only during
   the current call, materialize a temporary callback object anchored across the
   call.
3. Bare callbacks with no context pointer. Reject these in v1 unless the value
   is a compile-time-known singleton callback. Portable C cannot create an
   arbitrary per-closure function pointer without either a finite trampoline pool
   or libffi-like machinery.
4. Bare stored callbacks. For `int (*cb)(int)` with no context pointer, use a
   generated static trampoline pool per signature. Each thunk has a baked slot id
   and dispatches through module/runtime callback state. This avoids libffi but
   has a finite slot count and must reject exhaustion cleanly.
5. Optional future: libffi closure support for unlimited bare callbacks, if the
   dependency is acceptable.

Thunk bodies convert C arguments to Titan values, call the exact Titan native
entry with the retained `_mod` and `CClosure *`, then convert the result back to
the C return type. A later phase can allow generic Lua callables through the Lua
stack. Errors crossing a C callback boundary should not longjmp through
arbitrary C by default; v1 should catch and store the error on the callback
object, return a zero/null value, and let the registering Titan code query or
rethrow where the C API permits.

## Implementation plan

### Phase 0 - pin behavior and fixtures

- Add header fixtures under `spec/fixtures/ffi/`.
- Add parser/checker tests proving current gaps: struct fields, union fields,
  function pointers, arrays, unsupported scalar spellings.
- Add design-target tests as pending or skipped if the project uses that style,
  or keep them in the plan until implementation starts.

### Phase 1 - official C type model

- Add `Type.C*` constructors in `types.lua`.
- Update equality, compatibility, stringification, GC classification, and the
  public-interface rejection path that prevents C types from reaching
  serialization.
- Convert `foreigntypes.lua` to produce official C types.
- Preserve declaration provenance: header, C spelling, source name, skipped
  reason.
- Extend `Ast.TypeQualName` checking so qualified names can resolve C type
  members from foreign modules.
- Keep C types local-only; reject every exported Titan interface position that
  contains a C type with a clear message.
- Add a module-interface validation pass that walks exported function
  params/returns, exported variables, record fields, and record method/static
  signatures looking for `Type.C*`.
- Implement the C/Titan/value conversion matrix before broadening imported
  declarations, so later features share one coercion policy.

### Phase 2 - richer declaration conversion

- Convert struct and union fields recursively.
- Convert C primitive spellings: signed/unsigned char, short, int, long,
  long long, float, double, size_t and other typedefs.
- Convert pointer-to-function and typedef'd function pointer types.
- Preserve C array types enough for rejection and allocation sizing.
- Add enum value capture through compiler-assisted probing or generated C
  constants.

### Phase 3 - C field access

- Extend checker `VarDot` for borrowed and owned pointers to C composites.
- Add C lvalue/rvalue codegen helpers.
- Implement field reads and writes for scalar, pointer, struct pointer, union,
  and string reads.
- Reject unsafe `char *` field writes unless explicitly copied or owned.
- Add coder tests that compile and run against a local fixture header.

### Phase 4 - owned allocation

- Add runtime/codegen helpers for inline `luaS_newudata` C payload allocation,
  type tags, and optional cached counts.
- Generate per-C-type metatables or type tags.
- Implement `C.Type.new()` and `C.Type.new_array(n)` for complete composites.
- Make owned-to-borrowed pointer coercion explicit in checker/codegen.
- Add GC stress tests proving owned allocations remain anchored during calls and
  are reclaimed by Lua without a finalizer.
- Add a separate later path for explicit adoption of external allocations with
  finalizers.

### Phase 5 - function pointers and callbacks

- Add `Type.CFunction` and `Type.CPointer(CFunction)`.
- Allow imported C functions to decay to C function pointers in foreign
  contexts.
- Implement context-pointer callback thunks first.
- Add explicit callback objects for stored callbacks, rooted by userdata and
  registry references.
- Add bare static trampoline pool support only after the context-pointer path is
  solid.
- Add tests for synchronous callbacks, stored callbacks, callback lifetime, and
  error propagation policy.

### Phase 6 - arrays and pointer operations

- Add C array indexing and pointer arithmetic deliberately, with documented
  indexing semantics.
- Add owned arrays with bounds metadata for Titan-side access. Passing to C is
  still unsafe and zero-overhead after unwrap.
- Add the remaining explicit casts among C pointer/integer/function-pointer
  types after the core `void *`, owned-to-borrowed, and value-handle casts are
  implemented.

### Phase 7 - docs and ABI

- Update `doc/language/ffi.md`.
- Update `doc/implementation/ffi-internals.md`.
- Link any new chapters from both implementation and language indexes if the
  feature becomes large enough.
- Document that C FFI types are module-local in v1 and cannot appear in exported
  Titan module interfaces. Future cross-module support needs include provenance
  in generated C, not just `types.serialize` work.

## Testing plan

Checker specs:

- `foreign import` records skipped unsupported declarations with reasons.
- Struct pointer field read/write typechecks.
- Union field read/write typechecks without active-variant tracking.
- Owned pointer coerces to borrowed pointer only in C contexts.
- Foreign C types can be written in internal/local type annotations through
  qualified names such as `H.ProbePoint`.
- C types in any exported Titan module interface are rejected because consumers
  would also need the referenced C headers included in their generated C.
- C-to-C, Titan-to-C, C-to-Titan, and `value` boxing/unboxing casts follow the
  documented matrix, including rejected unsafe cases.
- Unsafe `char *` field storage is rejected.
- Titan function to C callback accepts only representable signatures.

Coder specs:

- Direct C calls still emit and run as bare calls.
- Struct and union fields compile and run against a fixture header.
- Owned inline allocation is reclaimed by Lua under forced GC without a
  finalizer.
- Owned object passed to C remains anchored across calls that allocate.
- Context-pointer callbacks call back into Titan/Lua and return converted
  values.
- Callback object kept alive supports stored callbacks; collected callback is
  rejected or reports a controlled error.

Regression specs:

- Existing SDL and libc examples continue to compile.
- Existing pointer truthiness, `nil` pointer compatibility, and `void *` casts
  keep their documented behavior.
- Unsupported C declarations do not crash the compiler.

## Main risks

1. Callback lifetime and error propagation. C has no uniform exception path, and
   bare callbacks lack a context pointer. Start with context-pointer callbacks.
2. Cross-module leakage. C-aware types crossing Titan module boundaries require
   generated C include provenance as well as serialization and an ABI bump. V1
   avoids this by rejecting all exported C types.
3. Header parser coverage. Real headers contain extensions. Keep the system C
   compiler in the loop for layout and validation.
4. String lifetime. Zero-copy `string -> char *` is fine for call arguments but
   unsafe for stored fields or callbacks.
5. Silent unsafety. The FFI is allowed to be unsafe, but lifetime-changing
   operations should be visibly explicit rather than hidden in innocent-looking
   assignments.

## Recommended first milestone

Implement a narrow vertical slice:

```lua
local H = foreign import "ffi_probe.h"

function main(args: {string}): integer
    local p = H.ProbePoint.new()
    p.x = 7
    p.y = 3.5
    H.consume_point(p)
    return H.sum_with_context(function (x: integer): integer
        return x * 2
    end)
end
```

This slice proves the redesign's core value:

- no hand-written bridge C,
- direct generated C calls,
- C struct field syntax,
- GC-tracked caller allocation,
- callback thunking,
- and clear boundaries for unsafe behavior.
