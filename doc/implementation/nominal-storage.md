# Native nominal storage

Records and union variants remain one Lua `Udata *` with metatable identity.
Their storage has two independent regions: a dense traced uservalue vector and
an untraced C payload. `titan-compiler/nominallayout.lua` classifies erased
runtime types and builds the plans (`nominallayout.record`,
`nominallayout.variant`) that `titan-compiler/coder/nominal.lua` consumes
through `coder._nominal_plan`. Semantic field and part indices remain
declaration-order identities, never physical offsets.

## Traced and native regions

Strings, Arrays, Maps, functions, nominal values, owned C storage, `value`, exact
C `TValue`, Lua-internal `Udata *`, and options over traced values occupy UV
slots. Stores use the normal internal representation and userdata back barrier.
No collectable pointer is hidden in the raw payload. Native scalars, ordinary C
pointers/function pointers, fixed eligible C aggregates and arrays use C members.
A native optional member is a `{ int present; T value; }` struct.

A record plan assigns public UV fields first and private UV fields afterward.
This is a layout convention, not a GC requirement. The exported map associates
each logical field index with its dense UV index. Public native members form a
prefix struct that is the first actual subobject of the producer's full payload
struct; private native members follow it (`coder._nominal_declarations`). Every
ordinary importer lacking a direct `.titan` source-import edge—whether it
imports a compiled provider or a source-checked module in the same build—emits
only the compatible public prefix (`nominallayout.public` in
`coder._nominal_plan`). Only the defining module and its direct `.titan`
source importers emit the full layout from the checked source declaration, even
when a published public layout also exists for that owner. An ordinary importer
never fabricates producer-private types or casts an unrelated shorter struct
over flattened members. `getudatamem(u)` uses the object's actual `nuvalue`,
including its private traced slots. Public prefix members are named `_field_<name>` after the
public field name rather than its logical index, so the consumer's emitted
prefix stays stable when private fields move.

A variant payload starts with an actual `_titan_union_header` subobject holding
an unsigned tag, followed by that variant's native members. Only the active
variant's size and traced count are allocated. Empty variants have a raw tag
and no UV slots. `case` reads the header (`coder._nominal_tag`) and then the
selected plan's parts; logical part indices remain 1-based. Module state,
Interface wrappers, closures, Array proxies, and the coroutine's private UV
protocol retain their own layouts.

The C compiler supplies size, padding, member layout and alignment. A generated
typedef rejects payload or tail alignment exceeding Lua's `UValue` guarantee.
Constructors root the final userdata before any operation that can collect it.
A record with a `local` field gets a local synthesized `new`
(`titan-compiler/parser.lua` `defs.recorddecl`), so binary clients that see
only the public prefix cannot construct it; literal checks retain the total
logical field count even when private descriptors are omitted. For replacement
DSOs, a record literal or a direct constructor with fused allocation plans marks
the record's `literal` usage (`titan-compiler/checker/binary_usage.lua`). That
dependency rejects a provider whose newly private fields or `new` override
would break the consumer's inlined allocation.

## Fixed objects and borrowed projections

The checker attaches `_nominal_storage` to fixed complete non-GC C aggregates
and fixed arrays (`checker/c_types.lua`). Recursive GC-bearing content,
flexible-array-containing fixed objects, incomplete objects, and direct
function objects remain ineligible. The storage type remains the declared C
type, while a read (`coder._nominal_read`) projects a borrowed pointer to its
embedded object or first array element. The projection preserves explicit C
qualifiers; Titan binding `const` does not add C pointee constness.

Construction copies fixed objects. Argument snapshots happen at the argument's
lexical evaluation point, before a later argument can mutate the source. C
initialization and bytewise copies handle aggregates with const members;
ordinary C assignment cannot initialize those objects. An eligible whole-field
replacement still follows checker assignment rules. Interior writes do not
replace the binding. Borrowed projections do not allocate wrappers or retain
the owner: callers must keep the nominal value alive while using them. There is
no general aggregate-to-`value` conversion.

## Direct fresh constructor storage

Before generic instantiation or argument adjustment loses provenance,
`checker._direct_nominal_constructor` (`checker/calls.lua`) recognizes a
resolved synthesized record constructor or union variant constructor and
attaches `_nominal_constructor`. Each directly nested fresh `.new`/`.new_array`
expression receives a destination-specific allocation plan. Fixed destinations
initialize in the final payload. Const pointer/unsized-array record fields and
immutable union parts can instead receive an aligned trailing array or
flexible-array object. Mutable bindings and existing borrowed/owned values
retain ordinary conversion and ownership rules; first-class constructor calls
do not acquire this optimization.

`coder._codenominalcall` (`coder/nominalcalls.lua`) evaluates positional
arguments in source order and named arguments in recorded lexical order. It
snapshots ordinary fixed objects, checks each fresh count at that position, and
computes offsets without allocating an intermediate C owner. Checks cover
negative counts, integer-to-size narrowing, multiplication, FAM prefix size,
minimum object size, alignment padding, cumulative size and Lua's userdata
allocation limit. Empty arrays reserve distinct aligned addresses. After the
arguments succeed, one final `luaS_newudata` allocation is rooted, its native
region is zeroed, and tail pointers point into that same allocation. A tail
pointer is uncounted; fusion does not add bounds metadata to raw pointers.

The allocation guarantee is therefore exact: a direct constructor whose fixed
fields and fresh tails are all eligible performs one userdata allocation and no
temporary backing allocation, at any tail length including zero.
`spec/coder/nominal_storage_spec.lua` proves this for a native-array record
with a Lua allocator probe and by counting `luaS_newudata` in the generated
body.

## Exact native options and boxing

`coder/nativeoption.lua` supplies a typed presence/value carrier for options over
C integers and floats, including typedefs (`coder._is_native_option`,
`coder._native_option_ctype`). The carrier is used across native locals,
calls, returns, varargs, immediate-function results, and protected-control
spills. Other options retain their lossless `TValue` carrier. Aliases with the
same native carrier pass through without boxing.

Field access, assignment and case extraction do not narrow native C numbers.
A real Lua/value/reflection/Interface boundary invokes checked boxing
(`coder._native_option_box`) or a checker-owned conversion. A value outside the
Lua numeric representation can therefore live in a nominal but fail when a
field or part is boxed. Dynamic writes validate into a temporary before mutating
the field, preserving the old value when conversion fails. Generated record
accessors use the layout plan; union reflection uses its producer-owned
`TITAN_MT_PAYLOAD` reader: index 0 queries the active tag, -1 queries arity,
and positive indices read parts. Private variants are covered by that reader
without exporting their layout.

## Separate compilation and ABI

The graphcodec layout inventory (`nominallayout.encode`/`nominallayout.decode`)
is native-code metadata, separate from the semantic `_types` interface. DSO
modules export `<mangled>_layouts`; its byte string is pushed with
`lua_pushlstring` because it may contain NUL. Static inventories carry
`layouts` (`staticmetadata.lua`), and incremental objects carry `native.layouts`
(`objectmetadata.lua`). Selected-provider validation retains decoded plans in
the resolver context's `nominal_layouts`, with no process-global provider-layout
cache. Source consumers build full plans; binary consumers reconstruct exported
public plans.

Semantic `_types` serialization, analysis catalogs, and the language-server API
remain independent. Analysis can inspect ABI/types without requiring native
layout decoding. Native compilation requires complete physical metadata;
replacement DSO loading uses the separate [selective compatibility
projection](binary-compatibility.md). Public record field order, erased types,
and constness determine the stable prefix, while private traced/native storage
may change for consumers that do not construct the record. The layout protocol,
generated reflected projections, and default-construction callbacks are part of
the [compiled-module ABI](codegen-overview.md#compiled-module-abi); rebuild
code, providers and cached objects with the matching compiler and SDK.

## Native owners and callback access

A native handle, request, or parser struct lives inside its final nominal owner
as a fixed field: for example `loop_t`, `fs_t`, and `work_t` in
`titan/uv/uv.native.titan`, and the llhttp parser and settings in
`titan/http/parser.native.titan` `new_parser`. `buf_t.allocate` passes
`foreign char.new_array(capacity)` directly to the synthesized constructor, so
the byte storage is a const tail of the same userdata. Rules for these owners:

- Allocate the final owner before native initialization or submission receives
  any address; never copy an initialized handle or request into another owner.
  Copying an initialized struct is not equivalent even when the bytes match.
- An accepted request stays rooted by its loop's `requests` map until its
  completion runs. `work_after_callback` additionally pushes the owner on the
  Lua stack before `work_deliver` removes that map entry and clears `pending`,
  so the owner stays reachable through user delivery.
- When counting allocations for a public operation, count the native owner
  separately from callback closures, Task/Wait/operation/subscription records,
  retained descriptors and buffers, and domain results. A low native-storage
  count does not measure the whole operation, and callback-frame pins or
  retained request arguments are lifetime requirements, not duplicate owners to
  remove.

Restricted source foreign functions that directly import `titan/ffi.h` may use
`ffi.titan_record_field(owner, "Record", "field")` for a current-module record
(`checker/native_record_fields.lua`, `coder._foreign_record_field_read`). The
checker resolves literal names to a canonical field and the coder uses its
physical plan, evaluating the owner once. Traced fields yield a by-value
`TValue`; raw fields yield their exact C value, and fixed objects yield borrowed
pointers. Native optional fields are not supported by this private intrinsic.
The intrinsic allocates and roots nothing. It is a private trusted bridge, not
reflection or an exported header facility; foreign functions using it are kept
out of inline companion headers. Closure upvalue access continues to use the
distinct fixed closure protocol.

## Validation

Pure layout tests cover classification and public inventories; checker tests
cover eligibility, projections and direct fresh demand. Coder tests execute
mixed/raw/traced layouts, source-free providers, exact optional numerics,
lexical snapshots, count failures, alignment, and the single-allocation probe
above. Native library tests exercise GC during accepted operations,
cancellation and close, while reflection and JSON tests preserve public schema
behavior. See `spec/coder/nominal_storage_spec.lua`,
`spec/coder/native_optional_storage_spec.lua`, `spec/native_record_fields_spec.lua`,
and `spec/nominal_layout_spec.lua`.
