# Native nominal storage

Records and union variants remain one Lua `Udata *` with metatable identity.
Their storage has two independent regions: a dense traced uservalue vector and
an untraced C payload. `nominallayout.lua` classifies erased runtime types and
builds the plans consumed by `coder/nominal.lua`; semantic field and part indices
remain declaration-order identities, never physical offsets.

## Traced and native regions

Strings, Arrays, Maps, functions, nominal values, owned C storage, `value`, exact
C `TValue`, Lua-internal `Udata *`, and options over traced values occupy UV
slots. Stores use the normal internal representation and userdata back barrier.
No collectable pointer is hidden in the raw payload. Native scalars, ordinary C
pointers/function pointers, fixed eligible C aggregates and arrays use C members.
A native optional member has a presence flag and an exact base value.

A record plan assigns public UV fields first and private UV fields afterward.
This is a layout convention, not a GC requirement. The exported map associates
each logical field index with its dense UV index. Public native members form an
anonymous prefix struct that is the first actual subobject of the producer's
full payload struct; private native members follow it. A binary consumer emits
only the compatible public prefix. It never fabricates producer-private types
or casts an unrelated shorter struct over flattened members. `getudatamem(u)`
uses the object's actual `nuvalue`, including its private traced slots.
Generated C names for public native members depend on public field names rather
than private-interleaved logical indices. This keeps the consumer's emitted
prefix stable when private fields move without changing semantic index or
layout-metadata formats.

A variant payload starts with an actual `_titan_union_header` subobject holding
an unsigned tag, followed by that variant's native members. Only the active
variant's size and traced count are allocated. Empty variants have a raw tag
and no UV slots. `case` reads the header and then the selected plan's parts;
logical part indices remain 1-based. Module state, Interface wrappers, closures,
Array proxies, and the coroutine's private UV protocol retain their own layouts.

The C compiler supplies size, padding, member layout and alignment. Generated
checks reject payload or tail alignment exceeding Lua's `UValue` guarantee.
Constructors root the final userdata before any operation that can collect it.
Records with private fields cannot be constructed by incomplete binary clients: their
synthesized constructor is private, and literal checks retain the total logical
field count even when private descriptors are omitted.
For replacement DSOs, record literals also record a public `new` compatibility
dependency. This rejects a newly private constructor before an old consumer
can perform an inlined allocation using the earlier complete layout.

## Fixed objects and borrowed projections

The checker attaches `_nominal_storage` to fixed complete non-GC C aggregates
and fixed arrays. Recursive GC-bearing content, flexible-array-containing fixed
objects, incomplete objects, and direct function objects remain ineligible.
The storage type remains the declared C type, while a read projects a borrowed
pointer to its embedded object or first array element. The projection preserves
explicit C qualifiers; Titan binding `const` does not add C pointee constness.

Construction copies fixed objects. Argument snapshots happen at the argument's
lexical evaluation point, before a later argument can mutate the source. C
initialization and bytewise copies handle aggregates with const members;
ordinary C assignment cannot initialize those objects. An eligible whole-field
replacement still follows checker assignment rules. Interior writes do not
replace the binding. Borrowed projections do not allocate wrappers or retain
the owner: callers must keep the nominal value alive while using them. There is
no general aggregate-to-`value` conversion.

## Direct fresh constructor storage

Before generic instantiation or argument adjustment loses provenance, the
checker recognizes a resolved synthesized record constructor or union variant
constructor and attaches `_nominal_constructor`. Each directly nested fresh
`.new`/`.new_array` expression receives a destination-specific allocation plan.
Fixed destinations initialize in the final payload. Const pointer/unsized-array
record fields and immutable union parts can instead receive an aligned trailing
array or flexible-array object. Mutable bindings and existing borrowed/owned
values retain ordinary conversion and ownership rules; first-class constructor
calls do not acquire this optimization.

`coder/nominalcalls.lua` evaluates positional arguments in source order and
named arguments in recorded lexical order. It snapshots ordinary fixed objects,
checks each fresh count at that position, and computes offsets without allocating
an intermediate C owner. Checks cover negative counts, integer-to-size narrowing,
multiplication, FAM prefix size, minimum object size, alignment padding, cumulative
size and Lua's userdata allocation limit. Empty arrays reserve distinct aligned
addresses. After the arguments succeed, one final userdata allocation is rooted,
its native region is zeroed, and tail pointers point into that same allocation.
A tail pointer is uncounted; fusion does not add bounds metadata to raw pointers.

## Exact native options and boxing

`coder/nativeoption.lua` supplies a typed presence/value carrier for options over
C integers and floats, including typedefs. The carrier is used across native
locals, calls, returns, varargs, immediate-function results, and protected-control
spills. Other options retain their existing lossless `TValue` carrier. Aliases
with the same native carrier pass through without boxing.

Field access, assignment and case extraction do not narrow native C numbers.
A real Lua/value/reflection/Interface boundary invokes checked boxing or a
checker-owned conversion. A value outside the Lua numeric representation can
therefore live in a nominal but fail when a field or part is boxed. Dynamic
writes validate into a temporary before mutating the field, preserving the old
value when conversion fails. Generated record accessors use the layout plan;
union reflection uses its producer-owned `TITAN_MT_PAYLOAD` reader: index 0
queries the active tag, -1 queries arity, and positive indices read parts.
Private variants are covered by that reader without exporting their layout.

## Separate compilation and ABI

The separate graphcodec layout inventory is native-code metadata. DSO modules
export `<mangled>_layouts`; its byte string is pushed with `lua_pushlstring`
because it may contain NUL. Static inventories carry `layouts`, and incremental
objects carry `native.layouts`. Selected-provider validation retains this data
in the resolver context, with no process-global provider-layout cache. Source
consumers build full plans; binary consumers reconstruct exported public plans.

Semantic `_types` serialization, analysis catalogs, and the language-server API
remain independent. Analysis can inspect ABI/types without requiring native
layout decoding. Native compilation requires complete physical metadata;
replacement DSO loading uses the separate [selective compatibility
projection](binary-compatibility.md). Public record field order, erased types,
and constness determine the stable prefix, while private traced/native storage
may change for consumers that do not construct the record.
The prerelease ABI marker remains 2 and the compiler version remains 0.6.0.
Rebuild code, providers and cached objects with the matching compiler and SDK;
no adapter reads the old all-UV layout. Native imports require the new separate
layout protocol even though the version marker is unchanged.

## Native owners and callback access

Standard-library handles/requests now live inside their final nominal owner.
Allocate that owner before initializing libuv/llhttp state; never copy an
initialized handle into it. The fs read buffer, WorkOwner carrier, and spawn
stdio array use final-owner tails. Existing Task pending roots, Runtime handle
roots, submission failure cleanup, cancellation and close callbacks remain the
lifetime protocol. Work callbacks explicitly stack-root their owner across
resumption, which clears `Task.pending` before running user code.

Restricted source foreign functions that directly import `titan/ffi.h` may use
`ffi.titan_record_field(owner, "Record", "field")` for a current-module record.
The checker resolves literal names to a canonical field and the coder uses its
physical plan, evaluating the owner once. Traced fields yield a by-value `TValue`; raw fields yield their exact C value,
and fixed objects yield borrowed pointers. Native optional fields are not
supported by this private intrinsic. The intrinsic allocates and roots nothing.
It is a private trusted bridge, not reflection or an exported header facility;
foreign functions using it are kept out of inline companion headers. Closure
upvalue access continues to use the distinct fixed closure protocol.

## Validation

Pure layout tests cover classification and public inventories; checker tests
cover eligibility, projections and direct fresh demand. Coder tests execute
mixed/raw/traced layouts, source-free providers, exact optional numerics,
lexical snapshots, count failures, alignment, and a Lua allocator probe proving
one userdata allocation for a direct native-array record. Native library tests
exercise GC during accepted operations, cancellation and close, while reflection
and JSON tests preserve public schema behavior. See `spec/coder/nominal_storage_spec.lua`,
`spec/coder/native_optional_storage_spec.lua`, `spec/native_record_fields_spec.lua`,
and `spec/nominal_layout_spec.lua`.

The reproducible [allocation audit](nominal-allocation-audit.md) records isolated
storage measurements and checks the actual generated stdlib construction paths.
