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
3. C variadic functions should be callable, with casts through ordinary
   `as <C type>` where the caller must select a precise C width.
4. Titan-allocated C storage should be tracked by Lua/Titan GC, using `Udata`,
   and must stay anchored when unwrapped for C calls.
5. C struct and union fields should use normal Titan field syntax.
6. C interop is unsafe; Lua gradual-typing guarantees do not extend across it.
7. FFI values that reach Lua may be opaque lightuserdata or userdata.
8. Passing Titan functions to C callbacks is explicitly out of scope for this
   iteration and belongs in the future roadmap.
9. C indexing uses `exp[index]` with 0-based semantics; `#exp` is supported for
   static C arrays and counted owned C arrays.
10. `CAdopted` and owned allocation for structs with flexible array members are
    parked out of v1.

Related follow-up note: `.agents/plans/c-ffi-lua-api-followup.md` sketches why
"strong enough to call Lua API functions" should be handled after this v1
redesign instead of being bundled into it.

## Research workflow

Three explorer tracks were launched:

- Current FFI pipeline, type model, and migration risks.
- C structs/unions/pointers, owned allocation, and field access syntax.
- Function pointer/callback risks and Titan first-class function
  representation, to separate v1 work from future callback support.

The tracks agreed on the main direction: keep `foreign import`, promote ad-hoc
C types into official internal type tags, keep `p.x` field syntax, separate C
field lvalues from Titan record fields, use full userdata for owned C
allocation, model C function pointers separately from Titan `Type.Function`,
and leave Titan-to-C callback adaptation out of v1.

## Evidence map

- Roadmap: `README.md` lists "FFI with C, continued (other C primitive types,
  C arrays, C structs/unions including pointers, function pointers)" as next.
- Current language behavior: `doc/language/ffi.md` documents direct header
  import, direct calls, opaque pointers, and current limitations.
- Current implementation: `doc/implementation/ffi-internals.md` documents the
  compile-time C toolchain, the current `Type.ForeignModule` name that v1
  should rename to `Type.CModule`, ad-hoc `Type.Pointer` and `Type.Typedef`,
  direct `codeforeigncall`, and field stubs.
- Parser: `titan-compiler/parser.lua` already lowers `e.name` to `Ast.VarDot`,
  so C field access does not need new surface syntax.
- Checker: `titan-compiler/checker.lua` resolves `VarDot` only for Titan
  modules, current foreign modules, record statics, and Titan record fields.
  Pointer to C composite field access is absent.
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
  callback ABI. This is why Titan-to-C callback adaptation is parked for a
  later design rather than treated as a small cast.

## Local experiments

Experiment source: `.agents/plans/c-ffi-redesign-experiments/ffi_probe.c`

Build command:

```sh
cc -I lua-5.5.0/src -Wall -Wextra -Werror \
  -o /tmp/titan_ffi_probe \
  .agents/plans/c-ffi-redesign-experiments/ffi_probe.c \
  lua-5.5.0/src/liblua.a -lm -ldl
```

Run output:

```text
layout:size=32 x=0 y=8 u=16 union.double=8
owned-inline:x0=7 y0=3.5 u0=11 x1=13 len_count=2 uv_count=2 tagged=yes anchored=yes
owned-after-gc:no-finalizer-needed
```

What this validates:

- Struct layout must be left to the C compiler. The probe struct has padding
  before `double y`; Titan should emit C field expressions and `sizeof(T)`
  rather than try to reproduce ABI layout in Lua.
- A full Lua userdata can store the C object bytes inline, recover the element
  count from `Udata.len`, and use user values for metadata such as a C type tag
  and cached count. No finalizer is needed for Titan-owned inline storage.

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
- C variadic calls remain direct C calls after the checker/codegen has converted
  each fixed and variadic argument to the chosen C type.
- C field reads/writes become `ptr->field` or `value.field`.
- C allocation uses `sizeof(C_TYPE)` in generated C, not a Lua-computed layout.
- Owned C storage is a Lua full userdata whose raw payload stores the C object
  bytes inline. User values carry metadata such as a type tag and, when useful,
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

Imported named C types should appear as module members in a type-namespace
role:

```lua
local H = foreign import "/tmp/probe.h"
local ffi = foreign import "titan/ffi.h"

local p = H.ProbePoint.new()
p.x = 10
p.y = 4.5
H.consume_point(p)

local n = ffi.int32_t.new()
local bytes = ffi.uint8_t.new_array(1024)
```

`H.ProbePoint` is not a Titan record and not an ordinary first-class value. It
is a C type namespace, similar in spirit to a record static namespace:

- `H.Type.new()` returns a GC-owned object of that C type, zeroed in the
  userdata payload.
- `H.Type.new_array(n)` returns a GC-owned array of `n` inline elements.
- These pseudo-functions apply to any complete C object type with a defined
  `sizeof(T)`: primitive C scalars, enums, pointers, structs, unions, and
  typedefs thereof. Reject `void`, function types, incomplete composites, and
  other non-object types.
- `H.Type.sizeof` and `H.Type.alignof` can be constants once layout probing
  exists.
- Later, `H.ProbePoint.wrap(ptr)` can create a borrowed view. Explicit adoption
  of C pointers returned by libraries, with a finalizer or release function, is
  parked out of v1; it is a separate mode from Titan-owned inline allocation.

The exact method names can change, but the important point is that allocation is
available from the imported header namespace without manual bridge C, and it is
not restricted to aggregates.

### Compiler-provided primitive header

To make primitive C allocation and C vararg casts usable without requiring every
program to invent a local header, Titan should ship a small FFI header. The
exact include spelling can be decided with the rest of the compiler include
path, but the intended user surface is:

```lua
local ffi = foreign import "titan/ffi.h"

local count_box = ffi.size_t.new()
local buf = ffi.uint8_t.new_array(4096)
local count = 4096
C.printf("%zu\n", count as ffi.size_t)
```

In that example `count_box` and `buf` are owned C storage, while `count as
ffi.size_t` casts an ordinary Titan value to the C width expected by `printf`.

The header should expose C99 primitive and standard typedef names in a stable
form: signed and unsigned character/integer widths from `<stdint.h>`,
`size_t`, `ptrdiff_t`, `intptr_t`, `uintptr_t`, `_Bool`/`bool`, `float`,
`double`, and spelling aliases for ordinary C `char`, `short`, `int`, `long`,
and `long long` where useful. It is a convenience header, not a new runtime
library: imported names still lower to ordinary C types in generated C.

### C types in Titan annotations

V1 should lift a prototype limitation: imported C FFI types must be usable in
Titan type annotations, not only inferred from foreign calls. The existing
parser already has `Ast.TypeQualName` for `module.Type`; the checker should
extend that rule so a qualified type name may resolve through a `CModule` as
well as a Titan module.

Examples:

```lua
local H = foreign import "/tmp/probe.h"

local function bump(p: H.ProbePoint): nil
    p.x = p.x + 1
end

local count: H.size_t = H.size_t.new()
```

The exact names exposed by a `CModule` are part of the C type namespace:
`H.ProbePoint` might denote the default owned inline representation for
`struct ProbePoint`, while primitive typedefs such as `size_t` should preserve
the imported C typedef name. If v1 needs annotations that cannot be expressed
as today's single `NAME.DOT.NAME` grammar, it should either add explicit syntax
or expose additional type-namespace members rather than falling back to
inference only.

Checker work:

- `Ast.TypeQualName` should accept a receiver whose type is `Type.CModule`.
- The C module needs a type namespace distinct from callable/value
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
p.u.int_value
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

### C arrays, indexing, and length

C indexing uses the same syntax as Titan array indexing:

```lua
local item = xs[i]
xs[i] = item
local n = #xs
```

The receiver may be a `CPointer(T)`, a `CArray(T, N)` static C array type
(`T[N]`, including through typedefs and struct fields), or a `COwned(T)` value
with count metadata, after resolving typedefs.

Rules:

- Indexing is 0-based, matching C.
- The index expression is checked as an integer value and materialized once.
- `CArray(T, N)` indexes are bounds-checked against the static length `N`.
- `COwned(T)` indexes are bounds-checked against the dynamic count stored on
  the owned userdata. `T.new()` has count 1; `T.new_array(n)` has count `n`.
- Bare `CPointer(T)` indexing is unsafe and does not get a bounds check,
  because no length is available.
- `#exp` is valid for `CArray(T, N)` and counted `COwned(T)`, returning a Titan
  `integer`: the static length for `CArray`, the dynamic count for `COwned`.
- `#exp` is rejected for bare `CPointer(T)` and any owned value whose count is
  unavailable.

This deliberately makes C indexing visually familiar but semantically foreign:
the receiver type controls the 0-based indexing and bounds policy. Titan arrays
remain 1-based.

Flexible array members need special handling and are not supported for owned
struct allocation in v1. If a struct has a C flexible array member, v1 should
record that fact, allow fixed-prefix metadata where practical, but reject
`Struct.new()`/`Struct.new_array(n)` for that struct and reject indexing or
`#` on the flexible member. Supporting this later requires an allocation API
that accepts the flexible-member element count and stores enough metadata to
bounds-check the flexible member.

### Function pointers

Imported C function-pointer types should become C function pointer types, not
ordinary Titan function types. `Type.Function` means a boxed Titan/Lua callable;
`Type.CFunction` means a raw C ABI signature.

V1 should support function-pointer types as C values: declarations can mention
them, structs can contain them, `nil` can initialize or compare them, imported C
functions can decay to matching C function-pointer values, and compatible C
function pointers can be passed through to C calls. This does not imply that a
Titan function value can be converted to a C callback.

Passing Titan functions to C is parked for a later design. The hard parts are
lifetime, error propagation across arbitrary C, stored callbacks, no-context
bare function pointers, and the fact that Titan native entries need `_mod` and
the exact callee `CClosure *`, not just a raw native code pointer.

### C variadic functions

C declarations with `...` should be callable in v1. This is important enough to
be part of the first useful FFI, because libc-style APIs such as `printf`,
`snprintf`, `fcntl`, and many system wrappers use C varargs.

Rules:

- Fixed parameters are checked and converted exactly like ordinary C calls.
- Variadic tail arguments are emitted as direct C call arguments after codegen
  has materialized each side-effecting operand once.
- The compiler should apply C default argument promotions for C-typed variadic
  arguments where the static type is known: `float` to `double`, and integer
  types narrower than `int` to `int` or `unsigned int` according to C's rules.
- Titan scalar arguments may be accepted through documented default lowerings
  (`integer` and `float`), but portable code should use ordinary
  `as <C type>` casts whenever the C format or ABI requires a specific width.
- There should be no separate `as_int`-style construct. The regular Titan
  `as <type>` cast covers C vararg width selection, pointer/integer casts that
  v1 permits, and Titan-to-C numeric conversions.
- Titan `string` can be passed to `const char *`-style vararg positions for the
  duration of the call, with the same lifetime rule as fixed `char *`
  arguments.
- Reject Titan arrays, maps, records, and `value` in C vararg tails unless an
  explicit C cast/unboxing path is defined.
- Do not try to forward a Titan variadic `...` pack directly into a C vararg
  call in v1. Each C vararg argument should be visible to the checker.

The `ffi.h` primitive header gives users names for the common casts:

```lua
local C = foreign import "stdio.h"
local ffi = foreign import "titan/ffi.h"

C.printf("count=%zu value=%d\n", count as ffi.size_t, value as ffi.int)
```

## Internal type model

Move C types into `types.lua` instead of continuing ad-hoc tables. Suggested
tags:

- `Type.CVoid`
- `Type.CInteger { spelling, signed, rank, bits? }`
- `Type.CFloat { spelling }`
- `Type.CPointer { pointee, quals }`
- `Type.CArray { elem, len }`
- `Type.CFunction { params, ret, vararg, abi }`
- `Type.CStruct { cname, tagname, typedef, fields, complete, has_fam? }`
- `Type.CUnion { cname, tagname, typedef, fields, complete }`
- `Type.CField { owner, name, type, bitfield?, flexible_array? }`
- `Type.CTypedef { name, target }`
- `Type.COwned { pointee, count? }`
- `Type.CModule`, replacing the prototype's `Type.ForeignModule` name.

Do not add `Type.CAdopted` in v1. Explicit adoption of externally allocated C
memory, with finalizers and library-specific release functions, is future work.

This requires updating:

- `types.equals`
- `types.compatible`
- `types.coerceable`
- `types.explicitly_coerceable`
- `types.tostring`
- `types.serialize` should not need C-type cases in v1, because public Titan
  module interfaces cannot mention C types.
- `types.is_gc` for `Type.COwned` and opaque FFI handle userdata
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
not advance the compiled-module ABI for C type export.

Future support would need both pieces: type serialization/identity and generated
C include propagation or explicit re-import requirements in every consuming
module.

This export ban must be enforced after the checker has resolved annotations.
Do not preserve the prototype's old behavior where `Ast.TypeQualName` simply
failed for foreign modules. Rename that internal type to `CModule`, allow the
annotation first, then reject it
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
- If it is a Titan function passed to a C function pointer parameter, reject it
  in v1 with a diagnostic that Titan-to-C callbacks are future work.
- If the C function is variadic, convert the fixed arguments first, then convert
  each visible variadic tail argument using the C vararg rules above.

The coder must materialize side-effecting operands once before using them in
generated C expressions, following the existing codegen rule for binary ops.

### C casts and conversions

Use three distinct notions:

- **C assignment conversion:** implicit only in C contexts, such as an argument
  to a foreign call, assignment to a C field, a C variadic tail argument after
  default promotions, or initializing a C temporary.
- **Titan `as` cast:** explicit in source and allowed for unsafe reinterpretation
  or lossy conversion.
- **`value` boxing/unboxing:** explicit at the C boundary except for values that
  already are Lua GC objects, such as owned C userdata.

#### C-to-C conversions

Implicit in C contexts:

- Exact type after typedef resolution.
- Qualifier addition, such as `T *` to `const T *`.
- Object pointer to `void *`, preserving qualifiers.
- `nil` to any C pointer or C function pointer.
- `Type.COwned(T)` to borrowed `T *` or `void *`, by unwrapping while keeping
  the userdata anchored for the call.
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
  should be rare; v1 may reject them until the function-pointer cast policy is
  stable.

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
- Passing a Titan function value where C expects a function pointer. This is the
  parked callback feature.

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

- `Type.COwned` values are already full userdata, so converting them to `value`
  can hand out the same userdata object. Lua sees an opaque userdata.
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
payload. A finalizer-bearing wrapper for explicit adoption of external C
allocations returned by libraries is future work and should not be implemented
as `CAdopted` in v1. Borrowed pointers remain bare C pointers and are not GC
tracked.

### C variadic call codegen

For a C function declared with `...`, codegen should still emit a direct call:

```c
snprintf(buf, size, "%d %zu", (int)x, (size_t)n);
```

The checker should annotate each variadic tail expression with the exact C type
that codegen will emit. If the source expression already has a C type, apply
the C default promotions required for varargs. If the source expression is a
Titan scalar, either use the documented default lowering or require an explicit
`as <C type>` cast when the target width cannot be inferred safely.

This keeps `printf`-style calls honest: the format string is not a type
checker, so the Titan source must make width-sensitive choices visible through
ordinary casts such as `n as ffi.size_t` or `x as ffi.int`.

### Future roadmap: Titan functions as C callbacks

Titan-to-C callbacks should be designed after the core C type model, ownership,
fields, arrays, and C varargs are stable. The future design needs to address:

- Context-pointer callbacks, where the C API accepts both `fn` and `void *ctx`.
- Stored callbacks, where the Titan callable must be rooted beyond the current
  call.
- Bare no-context function pointers, which need either a finite generated
  trampoline pool or a dependency such as libffi closures.
- Error propagation across arbitrary C, where a Lua/Titan longjmp is usually not
  safe.
- Calling the exact Titan closure, including `_mod`, `_fn`, and captures, rather
  than treating a Titan function as a raw C function pointer.

V1 should reject Titan function values at C function-pointer boundaries with a
clear "callbacks are future work" diagnostic.

## Implementation plan

### Phase 0 - pin behavior and fixtures

- Add header fixtures under `spec/fixtures/ffi/`.
- Add parser/checker tests proving current gaps: struct fields, union fields,
  function pointers, arrays, unsupported scalar spellings.
- Add design-target tests as pending or skipped if the project uses that style,
  or keep them in the plan until implementation starts.

### Phase 1 - official C type model

- Add `Type.C*` constructors in `types.lua`.
- Rename the current `Type.ForeignModule` representation to `Type.CModule`.
- Update equality, compatibility, stringification, GC classification, and the
  public-interface rejection path that prevents C types from reaching
  serialization.
- Convert `foreigntypes.lua` to produce official C types.
- Preserve declaration provenance: header, C spelling, source name, skipped
  reason.
- Extend `Ast.TypeQualName` checking so qualified names can resolve C type
  members from `CModule`s.
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
- Detect flexible array members and mark their owner structs as not eligible
  for owned allocation in v1.
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
- Implement `C.Type.new()` and `C.Type.new_array(n)` for all complete C object
  types, including primitive scalars from imported headers.
- Reject owned allocation for structs with flexible array members.
- Make owned-to-borrowed pointer coercion explicit in checker/codegen.
- Add GC stress tests proving owned allocations remain anchored during calls and
  are reclaimed by Lua without a finalizer.
- Park explicit adoption of external allocations; do not implement `CAdopted`
  in v1.

### Phase 5 - function pointers and C varargs

- Add `Type.CFunction` and `Type.CPointer(CFunction)`.
- Allow imported C functions to decay to C function pointers in foreign
  contexts.
- Support `nil` for C function-pointer values and pass-through of compatible C
  function pointers.
- Reject Titan function values where C expects function pointers, with a
  callback-roadmap diagnostic.
- Preserve and strengthen support for C functions declared with `...`.
- Apply C default promotions to C-typed variadic arguments and require or
  preserve explicit `as <C type>` casts for width-sensitive Titan arguments.
- Add tests for `printf`/`snprintf`-style calls, fixed-plus-vararg checking, and
  rejection of unsupported Titan values in C vararg tails.

### Phase 6 - arrays, indexing, and length

- Add C indexing through ordinary `exp[index]` syntax for `CPointer`,
  `CArray`, and counted `COwned`, with 0-based semantics.
- Bounds-check `CArray` against its static length and counted `COwned` against
  its dynamic count; leave bare `CPointer` indexing unsafe and unchecked.
- Add the `#exp` unary length operator for `CArray` and counted `COwned`.
- Reject indexing/length on flexible array members in v1.
- Passing owned arrays to C is still unsafe and zero-overhead after unwrap.
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
- Document that Titan-to-C callbacks and direct Lua API support are roadmap
  follow-ups, not v1 deliverables.

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
- C indexing accepts `CPointer`, `CArray`, and counted `COwned`, resolves
  typedefs first, and uses 0-based semantics.
- `#exp` accepts `CArray` and counted `COwned`, rejects bare `CPointer`, and
  returns a Titan `integer`.
- Structs with flexible array members reject owned allocation and reject
  indexing/length on the flexible member.
- `CAdopted`/external adoption APIs are absent from v1.
- Titan function to C function-pointer conversion is rejected in v1.
- C vararg tail arguments typecheck with default promotions and explicit
  `as <C type>` casts.

Coder specs:

- Direct C calls still emit and run as bare calls.
- C variadic calls emit and run as bare calls, including width-sensitive casts
  through the compiler-provided primitive header.
- Struct and union fields compile and run against a fixture header.
- Static C array indexing is bounds-checked against the declared length.
- Counted owned array indexing is bounds-checked against the userdata count and
  `#owned` returns that count.
- Bare pointer indexing compiles to direct C indexing without a bounds check.
- Owned inline allocation is reclaimed by Lua under forced GC without a
  finalizer.
- Owned object passed to C remains anchored across calls that allocate.

Regression specs:

- Existing SDL and libc examples continue to compile.
- Existing pointer truthiness, `nil` pointer compatibility, and `void *` casts
  keep their documented behavior.
- Unsupported C declarations do not crash the compiler.

## Main risks

1. C vararg correctness. The C compiler cannot check `printf` formats against
   generated arguments, so width-sensitive calls need visible casts and tests.
2. Cross-module leakage. C-aware types crossing Titan module boundaries require
   generated C include provenance as well as serialization and an ABI bump. V1
   avoids this by rejecting all exported C types.
3. Header parser coverage. Real headers contain extensions. Keep the system C
   compiler in the loop for layout and validation.
4. String lifetime. Zero-copy `string -> char *` is fine for call arguments but
   unsafe for stored fields or retained pointers.
5. Silent unsafety. The FFI is allowed to be unsafe, but lifetime-changing
   operations should be visibly explicit rather than hidden in innocent-looking
   assignments.

## Recommended first milestone

Implement a narrow vertical slice:

```lua
local H = foreign import "ffi_probe.h"
local C = foreign import "stdio.h"
local ffi = foreign import "titan/ffi.h"

function main(args: {string}): integer
    local p = H.ProbePoint.new()
    p.x = 7
    p.y = 3.5
    H.consume_point(p)
    C.printf("x=%d y=%g\n", p.x as ffi.int, p.y as ffi.double)
    return 0
end
```

This slice proves the redesign's core value:

- no hand-written bridge C,
- direct generated C calls,
- C vararg calls with ordinary `as <C type>` casts,
- C struct field syntax,
- GC-tracked caller allocation,
- and clear boundaries for unsafe behavior.
