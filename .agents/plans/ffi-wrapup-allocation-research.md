# FFI wrapup allocation research

Status: research only. This file covers only the **owned flexible-array-member**
and **target-directed `.new` / `.new_array` automatic-storage** parts of
`.agents/plans/ffi-wrapup.md`. It does not implement them, and it does not modify
the draft.

Code references describe commit `b3d6653` (the `ffi-wrapup.md` draft commit).
Function names, rather than mutable line numbers, are the authority below.

## Executive conclusions

1. The imported-C model already preserves almost all declaration metadata the
   FAM work needs: an unsized final field is `Type.CArray(elem, nil-or-empty)`,
   `Type.CField.flexible_array` identifies it, and `Type.CStruct.has_fam`
   summarizes the owner. The missing pieces are allocation/count provenance and
   lowering, not another C parser.
2. A FAM field cannot simply become `COwned(elem, true)`. It is a borrowed
   subobject, and its bounds belong to the containing allocation. Direct
   `owner.fam[i]` / `#owner.fam` therefore need checker-owned expression
   metadata which the coder consumes. A raw `T *` must not magically recover a
   count after ownership provenance has been erased.
3. A FAM array has **two counts** and is not an ISO C array. Ordinary `T *`
   arithmetic advances by `sizeof(T)`, while each extended object needs a
   larger, aligned stride. The draft's
   `T.new_array(array_count, fam_count)` is not implementable as an ordinary C
   `T[array_count]`; its Titan indexing, decay, and C-interoperability semantics
   must be settled explicitly.
4. The FAM starts at `offsetof(T, fam)`, not at `sizeof(T)`. A robust extent is
   based on `offsetof(T, fam) + fam_count * sizeof(E)`, while retaining at least
   `sizeof(T)` in case the target gives the FAM struct additional tail padding.
   Multiple extended elements additionally need target-aligned stride rounding.
   All arithmetic must use the configured target compiler in generated C and
   retain the existing negative-count and `size_t` overflow checks.
5. The current `Checker.CPseudoNew` always advertises `COwned`; local inference
   sees an unknown demand slot and consequently infers the owner. The new rule
   has to be chosen while checking the **direct local initializer sink**, before
   generic result annotation/coercion. Rediscovering stack-versus-owner in the
   coder would violate Titan's checker-owned adjustment architecture.
6. A stack constructor must lower as the declared local's storage, not as an
   expression-local temporary. Otherwise it bypasses addressability,
   C-out-parameter mutation tracking, block lifetime, defer-tail predeclaration,
   and the existing `setjmp` spill analysis. Ordinary struct/array cases should
   reuse the `_c_automatic_object` / `_c_zero_init` path; FAM backing requires
   that path to learn an explicit storage address and byte extent.
7. The draft examples require initialized `c.T[N]` and `c.T[]`, but the parser
   currently permits source-written `c.T[N]` only in the special single,
   initializer-less local production and does not permit bare `c.T[]` at all.
   Parser and syntax-error work is therefore part of this allocation section.
8. The standard library has one top-level FFI `.new()` that remains owned, 16
   function-local `.new()` sites whose native object is retained by a record or
   callback, and one literal `.new_array(3)` retained by a spawn configuration.
   The 17 function-local escaping sites should receive explicit owned types.
   Dynamic character buffers remain owned without edits. The two literal
   standard-library test-support buffers are genuinely frame-local and are good
   dogfood for the new stack inference.
9. No escape analysis, stack-size hardening, historical-layout migration, or
   new runtime API is called for. Automatic storage keeps the existing C block
   lifetime contract; explicit `owned` remains the way to request GC lifetime.
10. The allocation changes alone do not require a Titan compiled-module ABI
    bump: C types are prohibited from serialized interfaces and FAM metadata is
    translation-unit-local. The full wrapup may bump the ABI for the separate
    runtime callback removal, but that is not caused by these two sections.

## Current representation and data flow

### Imported C declaration graph

The C parser and converter already carry the relevant facts:

* `c-parser/ctypes.lua:mark_flexible_array_member` marks a field whose sole
  declarator extent is empty (`[]`).
* `titan-compiler/foreigntypes.lua:populate_struct_or_union` converts that field
  to `Type.CField(owner, name, type, bitfield, flexible_array)` and ORs it into
  `Type.CStruct.has_fam`.
* The field type is the ordinary unsized `Type.CArray(elem, len, quals)`.
* `foreigntypes` compatibility/redeclaration comparison and
  `types.equals` already compare `has_fam` and `flexible_array`, so distinct
  declarations cannot silently disagree about this property.
* Ordered `owner.fields` retains the physical FAM descriptor; a helper can find
  the one `field.flexible_array` member without changing the positional
  `Type.CStruct` or `Type.CField` constructors.

A new Type tag is not justified merely to allocate a FAM. Prefer a shared helper
such as `types.c_flexible_array_member(T) -> field, elem` which resolves typedefs,
requires a complete `CStruct`, and verifies the existing metadata. Adding a
cached `_fam_field` underscore annotation is harmless if profiling calls for it;
it must not become serialized identity.

### Source grammar and AST

Current grammar deliberately restricts fixed arrays:

* `Ast.TypeCArray(loc, base, length)` already exists.
* `parser.lua:automaticlocaltype` recognizes only qualified `c.T[N]` (with a
  signed integer token retained for checker diagnostics) or a qualified C type.
* `automaticlocaldecl` is admitted only as one `local` with no `=` and produces
  `StatDecl(..., exps = {})` through `defs.automaticlocal`.
* `simpletype` rejects a following `[` with `CArrayOnlyAutomatic`, so
  `local x: c.T[3] = ...`, `local x: c.T[] = ...`, parameters, results, casts,
  and aliases cannot use those forms.

The draft's initialized fixed and unsized examples cannot parse today. The
smallest grammar change is a local-initializer-specific C-array target
production which reuses `Ast.TypeCArray` and permits either a positive literal
or an empty extent. Whether it should become a fully general type production is
an open language decision listed below. There is no need for a new AST tag if
`TypeCArray.length == false` denotes the source `[]` target.

The last sentence of the draft is also not mechanically satisfied by deleting a
checker branch. A no-RHS local is a special parser production; ordinary Titan
locals require `=` and do not currently synthesize `nil`. If the intended
failure is a semantic “nil cannot initialize C array” error rather than a syntax
error, the parser/action must turn the retired array form into an ordinary
`StatDecl` with an `ExpNil`, or an equivalent checker recovery node.

### Pseudo-constructor checking and local inference

At present:

* `checker.lua:c_pseudo_member` creates `Checker.CPseudoNew`:
  * `.new`: no parameters, result `COwned(T, false)`;
  * `.new_array`: one Titan `integer`, result `COwned(T, true)`.
* `Ast.ExpCall` recognizes that checker-only descriptor, runs
  `c_allocation_error`, checks exact positional arity, and calls
  `annotate_call_results`.
* `Checker.CPseudoNew` is never a first-class `Type.Function`, and direct-only
  syntax and top-level constant-constructor recognition should stay unchanged.
* `StatDecl` builds one expression-list `result_demand`. An untyped declaration
  contributes the dense `UNKNOWN_SLOT`; a typed declaration contributes its
  already-resolved type. `adjust_explist` passes that expected context to the
  call checker before it performs the sink coercion.
* Because the pseudo descriptor currently fixes the result as `COwned`, an
  untyped local infers the owner. Typed `owned *T`, `owned T[]`, and compatible
  borrowed pointer targets then use ordinary identity/pointer adjustment.
* After inference, `StatDecl` rejects every whole `CArray` initialization or
  inference as a copy. A constructor-bound fixed array will need a narrow
  exception: it is declaration-owned zero initialization, not a C array copy.

The direct local sink must be explicit in the checked plan. A robust shape is:

```text
ExpCall._c_allocation_plan = {
    kind = "c_allocation",
    storage = "automatic" | "owned" | "owned_borrow",
    payload_type = T,
    result_type = ...,
    array_count = checked count descriptor or false,
    fam_field = field or false,
    fam_count = checked count descriptor or false,
    automatic_type = T / CArray(T,N) or false,
}
Decl._c_allocation_plan = the same plan when storage is automatic
```

`StatDecl` can identify the direct sink through the existing expression-demand
callback machinery (which already receives the sink index) or an equally narrow
local-initializer context. Do not infer it from diagnostic strings such as
`demand.term`, and do not mutate a shared type relation after code generation
begins. Only the direct written pseudo-call delivered to that local qualifies;
a pseudo-call nested in another call/cast/initializer is not a local allocation
site.

### Existing owned allocation lowering

`coder.lua:codecpseudonew` currently:

1. evaluates a `.new_array` count once;
2. rejects a negative count at runtime;
3. checks `count * sizeof(T)` for `size_t` overflow;
4. calls `luaS_newudata(L, nbytes, 0)`;
5. stamps the per-module/per-C-type metatable;
6. immediately anchors the `Udata *` in a reserved Lua stack slot; and
7. zeroes the payload.

`Udata.len / sizeof(T)` supplies the dynamic count for ordinary owned arrays in
`codecindex_parts` and `#` lowering. `code_owned_payload` exposes
`getudatamem(owner)` for field/index/pointer operations. These are sound for
ordinary adjacent fixed-size elements and should remain the fast path.

A FAM scalar cannot reliably overload that formula, and a FAM array cannot: the
latter has both an outer count and a FAM count. Per-allocation metadata is
required. Private integer user values on the owner are the least disruptive
representation:

* scalar FAM owner: one user value for `fam_count`;
* FAM array owner: one for `array_count`, one for `fam_count`;
* ordinary owners: retain zero user values and the current `len / sizeof` path.

`luaS_newudata` already adjusts `getudatamem` for the requested number of user
values, so the C payload still begins at its normal aligned address and no
header is exposed to C. The slots carry integers and need no GC barriers. Counts
must be initialized before publication. A private payload trailer would also be
possible, but it makes `Udata.len` cease to be the exact C payload extent and is
harder to align/read safely; a prefix would move the C object and is unsuitable.

### Existing automatic objects and arrays

Initializer-less automatic objects are checked by:

* `automatic_c_object_error` / `automatic_c_layout_error`, which require a
  complete struct/union or positive fixed array and reject FAM structs;
* `types.c_automatic_gc_bearing`, which rejects embedded `TValue`, the special
  GC-bearing `Udata *`, nested owners, and recursive aggregate occurrences;
* `StatDecl`, which marks the statement/declaration `_c_zero_init` and
  `_c_automatic_object`.

The coder emits a real declaration `T local = {0}`. A direct struct/union local
can be adjusted to a compatible pointer by taking its address; a fixed array
uses ordinary C decay. Mutable C-call arguments mark the exact root declaration
in `_c_mutated_decls`. Whole-array copy, assignment, return, and capture remain
rejected. No escape analysis is attempted.

The new ordinary stack constructors should enter this same representation:

* `T.new()` -> a real zeroed `T` local;
* `T.new_array(N)` -> a real zeroed `T[N]` local;
* no call-expression temporary and no `luaS_newudata` in those branches.

This preserves persistent-lvalue checking, field/index assignment, C out
parameters, block lifetime, capture rejection, and generated declarators.

### `setjmp` / `longjmp` spilling

`coder.lua:analyze_try_spills` operates on `Ast.Decl` identity. It marks a local
when a protected region writes it and a post-`longjmp` catch/finally/continuation
can read it. Important pieces are:

* `collect_writes_stat(StatDecl)` treats declaration initialization as a write;
* `_lvalue_root_decl` walks direct C fields and array indexes to their aggregate
  root;
* C calls append spills for checker-recorded `_c_mutated_decls` only after a
  successful return, preserving the pre-call spill if the call longjmps;
* `spill_decl_init`, `spill_update`, and `spill_reload` use volatile byte arrays
  for C aggregates; and
* defer-tail locals are predeclared through the same declaration metadata.

Consequently, hiding automatic storage inside `codecpseudonew` would be wrong:
there would be no declaration for the analysis to mark. Ordinary constructor
locals should be real marked declarations and need almost no spill redesign.

FAM backing is the exception. `sizeof(local)` covers only the fixed prefix, and
a pointer variable is not the backing storage. The declaration plan must expose:

```text
storage_address(decl)  -- address of the first backing byte / first T
storage_bytes(decl)    -- compile-time C expression for the whole extended area
```

Generalize aggregate spill declaration/copy/reload to those helpers. Ordinary
objects continue to use `&local` and `sizeof(local)`; a fixed FAM constructor
uses its aligned backing and full byte extent. `_lvalue_root_decl` and mutable
C-call tracking must still return the source `Ast.Decl` when a FAM field/element
is reached. The volatile byte-copy loops should remain; introducing `memcpy`
would weaken the deliberate longjmp/volatile contract.

## Recommended target-directed semantics

The draft leaves several edges implicit. The following matrix is the smallest
policy consistent with its examples and Titan's existing architecture. Items
marked **decision required** are not safe to guess during implementation.

### Scope of the automatic-storage trigger

Use automatic storage only when all of these hold:

1. the pseudo-call is the direct value delivered to a newly declared ordinary
   function-local `Ast.Decl`;
2. the selected mode below is an automatic object/fixed array;
3. every required count is compile-time known under the chosen definition; and
4. the payload passes the existing complete-layout and non-GC-bearing automatic
   object checks.

Do **not** silently select stack storage for:

* module variables (they retain the current per-module owned root);
* assignment to an existing variable;
* record/union/Titan Array/Map initializer elements;
* arguments or returns in which the pseudo-call itself is the expression;
* a discarded call statement;
* surplus expressions in a multiple declaration; or
* a nested pseudo-call under another expression.

Multiple locals are not inherently excluded: each one-result pseudo-call that
is directly mapped to a real declaration slot can receive its own plan. A
trailing pseudo-call still has one result; ordinary expression-list arity and
missing/surplus diagnostics remain authoritative.

An option-shorthand local (`local x? = T.new()`) should retain an owned result,
because a direct C object/array has no `TValue` representation and cannot be the
base of Titan `Option`. This should be pinned by a checker test rather than
falling into an accidental `Option(CStruct)` error.

### `.new()`

For allocatable payload `T` at a direct local initializer:

| Local target | Recommended storage/result |
|---|---|
| inferred | automatic zeroed `T` when `T` is in the admitted automatic category |
| exactly `T` | automatic zeroed `T` |
| `owned *T` | zeroed owner userdata; local is the owner |
| compatible `*T` | zeroed anonymous owner userdata; local is a borrowed pointer to its payload and the hidden owner root lives through the function frame |
| any other context | current `owned *T` result, followed by ordinary sink checking |

A later coercion of an automatic `T` local to `*T` takes its address. A later
coercion to `owned *T` allocates one userdata, anchors it, and copies the object.
This is an allocating direct coercion, not identity, consistency, or subtyping.

**Decision required:** `.new()` is currently offered on primitive scalars,
enums, floating types, and pointer payloads as well as aggregates. The heading
says “aggregates,” while the rule says “if the local variable's type is not a
pointer type.” Decide whether inferred `ffi.int.new()` becomes a stack C integer
and whether a pointer-valued payload stays owned. Uniformly applying the written
rule to every complete non-pointer C object is coherent and makes `.new()` the
explicit zero initializer for C scalars; limiting it to structs/unions is also
coherent but must be stated. A C-pointer payload needs special care because
“target is a pointer” can mean either the payload value or a borrowed pointer to
that payload.

### `.new_array(count)`

For element `T`:

| Local target/count | Recommended storage/result |
|---|---|
| inferred, positive compile-time count `N` | automatic `T[N]` |
| inferred, runtime count | current `owned T[]` |
| exactly `T[N]`, matching positive compile-time `N` | automatic `T[N]` |
| exactly `T[N]`, runtime or mismatching count | compile-time error |
| `owned T[]`, any valid count | owned userdata even when count is literal |
| bare `T[]`, positive compile-time `N` | automatic backing, local is an uncounted borrowed pointer/view |
| bare `T[]`, runtime count | owned backing, local is an uncounted borrowed pointer/view with a hidden owner root |
| compatible `*T` | owned backing plus borrowed pointer, unless the language deliberately excludes this spelling in favor of `T[]` |
| non-local context | current `owned T[]` |

Only the constructor-bound fixed array bypasses the current whole-array
initialization rejection. Later whole-array inference/copy/assignment/return/
capture stays rejected.

Treat source `T[]` as an **allocation-target spelling for a borrowed pointer
view**, not as a normal incomplete C array object: C cannot declare a local
incomplete array. The cleanest semantic local type is `CPointer(T)` after target
selection, while retaining the written target on the allocation plan for
precise diagnostics. If it remains `CArray(T,nil)` internally, `cdeclarator`,
indexing, assignment, and decay all need special representation rules and it
must be distinguishable from an uncounted FAM field.

The borrowed view does not own or carry a public length. Indexing is raw-pointer
unchecked and `#view` is rejected; the hidden backing merely guarantees storage
lifetime. This avoids making `T[]` a second counted-owner type. If the intended
surface instead promises bounds on this view, that is a different type/provenance
feature and must be specified.

**Decision required:** a literal zero is a valid current owned allocation but is
not a positive C fixed-array extent. The least surprising compatibility rule is:
`new_array(0)` remains owned (or is an explicit compile-time error if the target
requires fixed storage), while only positive literals trigger inferred stack
arrays. Negative literals can be rejected at compile time; runtime negatives
retain the existing runtime error.

### Compile-time-known counts

Today source fixed extents are positive integer **literals**, and Titan has no
general constant-expression evaluator for local expressions. The examples
contrast a literal with a variable. Use a single checker helper and initially
mean:

* `Ast.ExpInteger` with a positive value for an outer fixed array count;
* `Ast.ExpInteger` with a nonnegative value for a FAM count.

Do not treat a mutable module local as compile-time known merely because its
initializer passed the separate top-level `isconst` test. If folded arithmetic,
alias constants, or `sizeof` are desired, they need an explicit target-aware
constant-expression contract rather than ad hoc syntax inspection in the
coder.

### Automatic-to-owned copy

Add one directional assignment operation for matching storage shapes:

* `CStruct`/`CUnion` (and any admitted scalar if the decision above includes it)
  -> `COwned(T, false)`;
* fixed `CArray(T,N)` -> `COwned(T, true)` with count `N`;
* compiler-provenance FAM automatic storage -> matching FAM owner while copying
  the exact extended byte extent and count metadata.

The operation should require exact payload identity/qualification and reject
unrelated aggregates. It should not lift structurally through Array, Map,
Function, or Option. A non-FAM by-value C result may be materialized and copied;
a FAM conversion requires a declaration/allocation plan because its type alone
does not carry the extent.

Lowering order is: materialize/freeze the source once, compute/check byte size,
allocate the destination userdata, stamp and root it immediately, copy bytes,
then publish the owner to the sink. For arrays and FAM backing use an exact byte
copy, not C array assignment. This operation needs a new closed coercion-plan
opcode and validation in both `types.lua` and `coder.lua`; the coder must not
infer permission from endpoints alone.

## FAM semantics and layout

### Constructor arity and eligibility

For a complete C struct with exactly one marked FAM `E fam[]`:

* `T.new(fam_count)` allocates one extended object;
* `T.new_array(array_count, fam_count)` allocates an outer collection whose
  elements all have the same FAM count;
* the old zero-argument `T.new()` and one-argument `T.new_array(n)` are arity
  errors for this `T`;
* non-FAM types retain their current arity;
* both counts are Titan integers evaluated exactly once in source order on the
  owned path;
* negative counts raise at the call location; every addition, multiplication,
  and alignment round-up is overflow checked before allocation.

`c_allocation_error` should stop blanket-rejecting a FAM only after the call has
selected this FAM-aware signature. It should continue rejecting `void`, direct C
functions, incomplete objects, C array typedef payloads, and nested owners.
Initializer-less ordinary automatic `local x: T` should continue rejecting a
FAM: it has no count.

### Recommended byte layout

Let `T` have FAM `E fam[]` and counts `m` (outer) and `n` (FAM):

```c
prefix = offsetof(T, fam);
end    = checked_add(prefix, checked_mul(n, sizeof(E)));
extent = max(sizeof(T), end);
stride = checked_align_up(extent, _Alignof(T));
bytes  = checked_mul(m, stride);
```

For scalar `.new(n)`, `m == 1`. Zero the entire `bytes`. Element `i` begins at
`(unsigned char *)payload + i * stride`, cast to `T *`; its FAM begins at the
real `offsetof` selected by the C compiler. Storing the logical counts
separately prevents target tail padding from manufacturing phantom FAM elements.
All of these expressions must be emitted against the configured target headers;
Lua-side/host-side layout guesses are invalid.

`max(sizeof(T), end)` is the conservative C-object floor. On mainstream targets
`sizeof(T)` and `offsetof(T,fam)` are normally equal, but C permits extra trailing
padding. Using `sizeof(T) + n*sizeof(E)` as if the member began at `sizeof(T)` is
not the logical layout and can overstate the accessible element count.

For stack storage use an aligned backing object, for example a union containing
`T` for alignment and an unsigned-byte array of the checked constant `bytes`.
The generated local expression can be a `T *`/dereferenced `T` facade over that
backing, but the declaration plan must retain the backing address and byte size
for spilling.

### Outer FAM-array warning

This layout is a Titan extension. ISO C does not define an array whose elements
are variably extended FAM objects, and a C callee doing `pointer[i]` advances by
`sizeof(T)`, not `stride`. Therefore:

* Titan's `owners[i]` must use the recorded stride, not ordinary C `base[i]`;
* `#owners` returns `array_count`;
* prefix-field and FAM access on that selected element use the computed `T *`;
* converting the collection to `T *` can safely name the first element, but a C
  API must not use ordinary pointer arithmetic to reach later extended
  elements unless its documented ABI accepts the same explicit stride.

**Decision required:** confirm that this custom-stride collection is what the
draft means. If ordinary C array interoperability is required, the requested
`new_array(array_count, fam_count)` shape has no honest representation; an array
of separately owned pointers or removal of that operation would be a different
API.

### FAM field indexing and length

Useful FAM allocation needs a public observation rule. Recommend:

* `#owned.fam` returns the stored `fam_count`;
* `owned.fam[i]` is 0-based and checked against that count;
* the same holds for `owned_array[j].fam` and for a compiler-created automatic
  FAM local with a compile-time count;
* `#owned_array` remains the **outer** count, never the FAM count;
* ordinary decay of `owned.fam` to `E *` remains available;
* `raw_pointer.fam` may decay to `E *`, but indexing or `#` is rejected because
  the pointer carries no allocation count;
* copying the unsized field into a local remains rejected, so count provenance
  is not accidentally detached from its owner.

Implement this with expression annotations, not by lying that the field is
`COwned(E,true)`. `c_field_decl` still returns the real `CField`; the checked
`VarDot` can attach a FAM access plan describing its containing allocation,
count source, stride source, and field descriptor. `c_index_elem_type` and
`has_c_length` need expression-aware variants. `codecfield`,
`codecindex_parts`, prepared-lvalue lowering, and unary `#` then consume that
plan while evaluating the base exactly once.

A field macro projection which resolves to the physical FAM should retain the
same flag/provenance; use the existing recorded public/physical field spelling
rather than inventing a second header view.

## Exact implementation change sites

The table is a change map, not an instruction to implement before the semantic
decisions above are answered.

| File / current owner | Required allocation work |
|---|---|
| `c-parser/ctypes.lua` (`mark_flexible_array_member`) | Probably no structural change. Retain the existing mark; add validation only if the current parser can produce more than one/non-final marked field from a valid accepted declaration. |
| `titan-compiler/foreigntypes.lua` (`populate_struct_or_union`, compatibility helpers) | Preserve ordered FAM field and `has_fam`; no new public type shape is necessary. If a cached FAM descriptor is added, keep it underscore-only and out of equality/serialization. |
| `titan-compiler/parser.lua` (`automaticlocaltype`, `automaticlocaldecl`, `defs.automaticlocal`, `simpletype`) | Parse initialized fixed and unsized local allocation targets; retire or narrow the no-RHS fixed-array branch; decide semantic-vs-syntax failure; allow `TypeCArray.length=false` for `[]`. |
| `titan-compiler/syntax_errors.lua` | Replace `CArrayOnlyAutomatic` / `CArrayExtent` wording and add precise missing/invalid initialized-target labels as needed. |
| `titan-compiler/ast.lua` | Existing `TypeCArray` is sufficient unless the language chooses a distinct borrowed-array-view AST. Document new checker annotations; avoid a new expression tag solely for allocation mode. |
| `titan-compiler/types.lua` (`COwned`, C helpers, `coercion_impl`, `assignment_adjustment`) | Add FAM lookup/layout-shape helpers and exact automatic-object -> owner coercion plan(s). Preserve `COwned(pointee,count)` unless the final semantics truly needs another type-identity dimension; runtime FAM counts are allocation metadata, not type identity. Audit `tostring`, equality, normalization, guardability, and serialization if any Type constructor changes. |
| `titan-compiler/checker.lua:c_pseudo_member` | Select FAM-aware arity; do not freeze a universal owner result before local context is known. |
| `checker.lua:c_allocation_error`, `automatic_c_layout_error`, `types.c_automatic_gc_bearing` call sites | Separate owned eligibility, ordinary automatic eligibility, and FAM-with-count eligibility. Keep no-count FAM automatic declarations rejected and reuse the GC-bearing ban for stack backing. |
| `checker.lua:StatDecl`, `result_demand`/`adjust_explist`, `annotate_call_results` | Bind a direct pseudo-call to its actual declaration sink; freeze allocation mode/result/counts; permit constructor-owned fixed-array initialization while retaining every ordinary whole-array rejection. Handle multi-local, option, discarded, and error recovery explicitly. |
| `checker.lua:trycoerce` / `checker_assignment_adjustment` | Attach the allocating aggregate-to-owner plan. FAM copy needs expression/declaration provenance analogous to mutable-address plans. |
| `checker.lua:c_field_decl`, `c_index_elem_type`, `has_c_length`, `VarDot`, `VarBracket`, unary `#` | Carry/consume FAM allocation provenance; accept bounded direct FAM observations and reject count-erased raw-pointer observations. Preserve persistent-storage checks. |
| `checker.lua` mutable C-call tracking (`mark_mutable_c_address_source`, `mutable_c_call_argument_decl`, `_c_mutated_decls`) | Treat constructor-backed/FAM facade locals as the same root declaration so C mutations commit to spills. |
| `titan-compiler/coder.lua:codecpseudonew` | Split owned ordinary/FAM allocation into a reusable helper. Automatic plans should be declaration-lowered and must not allocate an expression temporary. Add count metadata, `offsetof`/extent/stride arithmetic, overflow checks, metatable stamping, immediate rooting, zeroing. |
| `coder.lua:codestat_dispatch(StatDecl)`, `_codeinitializeddecl`, `predeclare_defer_tail` | Emit constructor-backed automatic declarations and aligned FAM backing; avoid C array assignment; retain unused-local and defer-tail behavior. |
| `coder.lua:nativetoforeignexp` / adjustment-plan validation and emission | Validate/lower automatic-to-owner allocation/copy, including result rooting and exact FAM metadata copying. |
| `coder.lua:codecfield`, `codecindex_parts`, prepared C lvalue helpers, `codeunaryop('#')` | Use FAM field count and custom outer stride; materialize receiver/count once; retain NULL/bounds timing and left-to-right assignment preparation. Refactor index parts to provide an element lvalue rather than assuming every base can use `base[index]`. |
| `coder.lua:_lvalue_root_decl`, spill helpers (`_aggregate_spill_copy`, `spill_decl_*`, `spill_reload`) | Use plan-provided backing address/byte extent for FAM storage and keep volatile byte loops. Ordinary `sizeof(local)` remains unchanged. |
| `titan-compiler/cdeclarator.lua` | Needed only if a semantic unsized `CArray` local is retained. If `T[]` contextualizes to `CPointer(T)`, existing pointer rendering suffices; aligned FAM backing remains a coder-owned special declaration. |
| generated C preamble / `titan-runtime/titan.h` | Ensure standard `offsetof` is available (prefer an explicit `<stddef.h>` include) and use the configured target's alignment operator already accepted by Titan's C99 toolchain. No runtime function is required. |
| manuals and indexes | Rewrite `doc/language/{ffi,c-ffi-expressions,grammar,index}.md` and `doc/implementation/{ffi-internals,c-ffi-expressions,index}.md`; update conversion tables and statements/types chapters where they describe no-RHS arrays or always-owned constructors. |

## Standard-library migration audit

The audit below distinguishes real FFI constructors from Titan record/union
`.new` calls.

### No migration required

* `titan/coroutine.titan:9`:
  `local runtime = mco.mco_runtime.new()` is a **module variable**, not a function
  local. It retains current owned allocation and module-state rooting.
* All inferred character `new_array` calls whose count is a runtime expression
  remain owners. This includes `titan/{http/native,math,os,ssl}.titan`,
  `titan/{peg,string}/**`, and the uv read/address/process buffers. Names such as
  `TLS_RECORD_BYTES` are mutable Titan variables, not source integer literals
  under the recommended compile-time-count rule.
* `spec/stdlib/titan/io/test_support.titan:27` (`int[2]`) and
  `spec/stdlib/titan/os/test_support.titan:127` (`char[256]`) are literal-count,
  strictly frame-local buffers. They should intentionally become stack arrays.
  The OS helper already explicitly casts the array to `*char` before its
  NUL-terminated string conversion.

### Add explicit ownership

Every function-local site below transfers the native object into a record/union
or callback owner which survives the allocating frame. Annotate the local as the
matching `owned *T` (or `owned T[]`) so it allocates directly and does not first
construct stack storage only to allocate/copy it later:

| Site | Required lifetime |
|---|---|
| `titan/http/native.titan:196-197` | `llhttp_t` and `llhttp_settings_t` are fields of returned `Parser`. |
| `titan/uv/file.titan:125` | `uv_fs_t` request survives until async callback. |
| `titan/uv/os.titan:188` | `uv_signal_t` survives through handle close/callback. |
| `titan/uv/process.titan:388` | `uv_pipe_t` is retained in `StdioNative`. |
| `titan/uv/process.titan:475` | `uv_tty_t` is retained in `StdioNative`/stdio cache. |
| `titan/uv/process.titan:642` | `uv_process_options_t` is retained by returned `uv_spawn_config`. |
| `titan/uv/process.titan:643` | literal `uv_stdio_container_t.new_array(3)` is retained by returned `uv_spawn_config`; write `owned libuv.uv_stdio_container_t[]`. |
| `titan/uv/process.titan:716` | `uv_process_t` is retained by returned process record. |
| `titan/uv/runtime.titan:114` | `uv_write_t` request survives until write callback. |
| `titan/uv/runtime.titan:230` | `uv_loop_t` is retained by returned `Runtime`. |
| `titan/uv/task.titan:491,536` | one-shot/repeating `uv_timer_t` handles survive callbacks. |
| `titan/uv/tcp.titan:264` | `uv_tcp_t` is retained by returned TCP record. |
| `titan/uv/tcp.titan:451` | `uv_getaddrinfo_t` request survives callback. |
| `titan/uv/tcp.titan:480` | `uv_connect_t` request survives callback. |
| `titan/uv/tcp.titan:534` | `uv_shutdown_t` request survives callback. |

The future aggregate-to-owner coercion would make most of these sites
functionally correct via an allocation/copy at the record constructor. Explicit
annotations are still the intended migration: they state lifetime, avoid a
redundant stack object/copy, and ensure the audit does not depend on a later
sink.

### Test and example migrations

Existing tests often use an inferred constructor specifically to assert owner
identity, dynamic bounds, GC rooting, or binary character-owner casts. Those
must become explicitly typed owners rather than being mechanically allowed to
change meaning. In particular audit:

* `spec/checker/c_ffi_spec.lua` owner index/length/pseudo-constructor cases and
  the old FAM rejection;
* `spec/coder/c_ffi_spec.lua` owned indexing, userdata identity, GC, and vararg
  cases;
* `spec/checker/c_ffi_stack_objects_spec.lua`, whose “keeps owned allocation
  constructors unchanged” case must be replaced by the new mode matrix;
* `spec/coder/c_ffi_stack_objects_spec.lua`, whose process-options/fixed-array
  shape should dogfood `.new()` / `.new_array(3)` and whose longjmp cases should
  use the new constructors;
* `spec/{checker,coder}/c_ffi_owned_types_spec.lua` bare inferred calls inside
  owner-specific tests (most aliases/locals are already explicit);
* `spec/coder/type_relations_soundness_spec.lua` and `unions_spec.lua` only where
  the test needs a GC owner rather than a direct call/return context.

A literal `char.new_array(N)` inferred local is now a fixed C array, so its old
binary-safe `owner as string` conversion no longer applies. Owner-behavior tests
and user examples must write `owned char[]`; pointer/NUL-string tests may cast
the stack array to `*char` deliberately.

## Focused test plan

### Parser and syntax

Add/update `spec/parser_spec.lua` cases for:

* initialized `local x: c.T[3] = c.T.new_array(3)`;
* initialized `local x: c.T[] = c.T.new_array(n)`;
* the chosen no-RHS `c.T[3]` failure shape;
* rejection or acceptance of fixed/unsized syntax outside the exact chosen
  local-target context;
* stable locations for zero, negative, noninteger, and missing extents.

### Pure type-relation tests

In `spec/types_spec.lua`, pin:

* exact `T -> owned *T` and `T[N] -> owned T[]` allocating adjustment plans;
* rejection for different aggregate/element/qualifier shapes;
* no Option/container/callable lifting;
* owner-to-pointer behavior remains unchanged;
* FAM type identity still depends only on existing C declaration metadata, not
  a runtime count.

### Checker tests

Extend `spec/checker/c_ffi_stack_objects_spec.lua` and
`c_ffi_spec.lua` with a compact fixture header containing an ordinary struct,
primitive, pointer typedef, ordinary array element, a deliberately aligned FAM,
and a FAM struct. Cover:

1. the full `.new` and `.new_array` target matrix (inferred, exact automatic,
   owner, raw pointer/view, fixed match/mismatch, runtime count);
2. module variables, assignments, call arguments, returns, discarded calls,
   option shorthand, and multiple locals, proving only direct new locals select
   stack storage;
3. literal-only compile-time selection, zero, negative, and runtime counts;
4. FAM arities and exact diagnostics;
5. automatic eligibility: incomplete, `void`, function, array typedef, embedded
   GC-bearing storage, and FAM-without-count remain rejected;
6. constructor fixed arrays are admitted but every unrelated whole-array copy,
   assignment, return, and capture remains rejected;
7. automatic-to-owner plans and FAM-provenance copy plans;
8. `#owner.fam`, `owner.fam[i]`, `#owners`, and
   `owners[j].fam[i]` accepted with the correct logical count;
9. FAM access through a raw `T *` rejects index/length while ordinary decay to
   `E *` remains legal;
10. direct/macro-projected FAM assignment roots and mutable C-call roots are the
    containing declaration.

### Coder/runtime tests

Use `spec/coder/c_ffi_stack_objects_spec.lua` for automatic storage/spills and
`spec/coder/c_ffi_spec.lua` (or one topical FAM spec if it becomes large) for
owned FAM behavior:

* Generated-C assertions: inferred ordinary constructors emit real `{0}` stack
  declarations and no `luaS_newudata`; explicit owner/raw-pointer and runtime
  arrays allocate userdata and anchor it before zero/copy.
* Ordinary behavior: zero initialization, struct fields, fixed array bounds/#,
  address coercion, C out-parameters, and block lifetime.
* Hidden-root behavior: a raw pointer target backed by anonymous owner remains
  valid across forced collections during the frame.
* FAM scalar: counts 0, 1, and several; prefix fields; exact `#fam`; first/last
  writes; negative/out-of-range diagnostics; dynamic count evaluated once.
* FAM array: two or more elements with different prefix/FAM contents, outer and
  inner lengths, and an element type whose alignment makes unrounded strides
  fail. Pass an individual selected element to a C helper, never rely on C
  `p[i]` for later elements.
* Layout: helper functions exposing `offsetof`, `sizeof`, alignment, and field
  addresses prove the target compiler owns layout. Pin overflow checks for FAM
  end, stride round-up, and outer multiplication without trying to allocate a
  huge object.
* Copy: automatic ordinary/fixed-array/FAM storage coerced to owner preserves
  all bytes/counts and remains valid after its source block exits.
* Longjmp: constructor-created struct/fixed array mutated directly and through a
  C out-parameter in a try is visible in catch/finally; a compile-time FAM stack
  object's **last FAM byte** survives, proving the spill covers the extended
  extent rather than only `sizeof(T)`. Include a defer-tail-predeclared case.
* GC/type identity: FAM owner round-trips through `value`, wrong owner shape is
  rejected by the metatable, and stored count user values survive collection.
* Preserve left-to-right evaluation and final-check timing for FAM field/index
  assignment.

Finally run the focused checker/coder specs, the complete compiler group, and
`make stdlib-test` after the explicit stdlib migrations. The async native suite
is the required proof that no libuv request/handle was accidentally moved to a
dead frame.

## Decisions to obtain before implementation

1. Does local `.new()` stack inference include primitive C scalars/enums/floats,
   and what exactly happens when `T` itself is a C pointer type?
2. Is “known at compile time” exactly a source integer literal, or a larger
   constant-expression language? What is inferred `new_array(0)`?
3. Is `c.T[]` only a contextual local allocation target, a semantic borrowed
   pointer, or a first-class unsized C-array view? Does it permit index or `#`?
4. Do module variables and every non-direct-local context retain always-owned
   pseudo-constructor results? The recommendation is yes.
5. Does the no-RHS removal apply only to fixed arrays (the literal wording) or
   to initializer-less structs/unions too (a possible reading of “removes the
   need”)? Should the retired form be a syntax error or a nil-initialization type
   error?
6. Confirm the custom aligned-stride meaning and limited C interoperability of
   FAM `new_array`; ordinary C array semantics cannot satisfy the draft.
7. Confirm that FAM fields become bounded/indexable only while parent allocation
   provenance is intact, and that raw-pointer access remains uncounted.
8. Confirm private Udata user values as count metadata, or specify another
   per-allocation representation.
9. Are by-value uses of an extended FAM local allowed to copy only the C fixed
   prefix, or should they be rejected so only pointer/field/owner-copy uses are
   legal? Rejection is less surprising.
10. Should automatic-to-owned copying be a general direct coercion for matching
    automatic C values, as the draft's wording implies, or only a constructor
    local special case? The general checker-owned coercion is the cleaner model.

## Suggested implementation order after decisions

1. Freeze the semantic matrix, FAM array layout, and `T[]` meaning in focused
   checker/parser tests.
2. Add FAM/type helpers and closed allocating coercion plans in `types.lua`.
3. Extend local grammar and bind direct pseudo-calls to declaration-owned
   allocation plans in the checker; keep all whole-array and eligibility
   rejections green.
4. Lower ordinary automatic constructors through existing declarations and
   spills; migrate the stack-object specs before touching FAM layout.
5. Add ordinary aggregate-to-owner allocation/copy and hidden raw-pointer roots.
6. Add FAM owned allocation/count metadata and scalar FAM access.
7. Add custom-stride FAM arrays, automatic FAM backing, prepared lvalues, and
   full-extent spills.
8. Apply explicit stdlib owner annotations and run the native async suite.
9. Update both manuals, indexes, grammar, active limitations, and examples in the
   same change.

## Non-goals and invariants

* No escape analysis: pointers to stack storage can dangle after the block/frame,
  exactly as documented for current automatic C objects.
* No adopted/external ownership mode or finalizer.
* No registry lookup or shared C global for counts; metadata belongs to the
  allocation itself.
* No host-layout guesses; all size/offset/alignment expressions are compiled by
  the configured target C compiler with the exact imported headers.
* No arbitrary count/stack-size cap. Retain negative and arithmetic-overflow
  checks at the actual allocation boundary.
* No broadening of C types into serialized public Titan interfaces.
* No compatibility or cleanup machinery for an ABI transition caused elsewhere
  in the full wrapup.
