# Separate FFI functions from Titan/Lua function values

## Status

Follow-up design note. This is intentionally outside the closure-adjustment-wrapper feature.

## Motivation

`Type.Function` currently has two different meanings:

1. a first-class Titan closure shape (also used as the checked view of a Lua callable cast from `value`), and
2. a direct C function declaration imported through the FFI.

`foreigntypes.convert_function` projects a `Type.CFunction` into a `Type.Function`, copies the C `...` bit into `Type.Function.vararg`, and retains the authoritative declaration in ad-hoc fields such as `_c_function`, `_c_return_type`, `_paramstyle`, and `_return_declaration_qualifiers`. That projection lets the ordinary call checker reuse `params` and `rettypes`, but it makes a non-value C declaration look like a Titan closure. The closure-adjustment work consequently has to exclude non-exact `Type.Function.vararg` shapes even though direct FFI functions can never have adjustment wrappers.

Titan variadic closures are unrelated to C `va_*` arguments. They use `Type.Function.varargtype` and Titan's `TitanVargX` native convention. Preserve that distinction.

## Target model

- `Type.Function` means only a callable GC value:
  - a Titan function/closure, or
  - a Lua callable entering through a `value` cast and invoked generically.
- Titan typed input tails remain `varargtype`; flexible result tails remain `flexrettype`.
- `Type.CFunction` is the authoritative signature of a direct FFI function declaration.
- A first-class C function pointer remains `Type.CPointer(Type.CFunction)` and is a bare C pointer, never a Titan closure.
- A direct imported C function may be called directly or contextually decay to a compatible C function pointer. It may not be stored or passed as a Titan/Lua `Type.Function` value.
- Closure adjustment, gradual callable guards, branding, strict relays, serialization, and wrapper code generation operate only on `Type.Function` and can never receive a C declaration by construction.

Do not introduce a second duplicate C signature. Reuse `Type.CFunction`; if declaration identity or namespace provenance needs a value-level carrier, add a narrow declaration descriptor that owns a `Type.CFunction` rather than decorating `Type.Function`.

## Implementation outline

### 1. Make the representation explicit

- Change `foreigntypes.convert_function` and C-module member construction to retain `Type.CFunction` directly.
- Keep C declaration details (`vararg`, ABI, old-style/prototype state, return qualifiers, origins, and typedef spellings) on the C graph.
- Remove the `Type.Function` `_c_function`, `_c_return_type`, `_paramstyle`, and `_return_declaration_qualifiers` compatibility path once no producer remains.
- Remove the foreign-C `vararg` role from `Type.Function`. Its constructor should carry only Titan/Lua callable shape information. Decide whether to remove the positional field immediately or in a mechanical follow-up; do not silently reinterpret it as the Titan typed tail.

Audit every Type tag visitor and serializer by hand as required by `AGENTS.md`. C-bearing types remain unexportable, so this should not change compiled-module metadata or ABI 0.22.

### 2. Share call checking without sharing the value type

Refactor the call checker around a neutral, checker-local call-signature view or helpers that accept either:

- a `Type.Function` with fixed parameters/results plus `varargtype`/`flexrettype`, or
- a `Type.CFunction` with C parameters, one C return (`void` maps to no Titan result), and its C `...` flag.

This is reuse of argument/result checking, not a type conversion. Keep the semantic branches explicit:

- Titan/Lua calls may use named arguments, callable adjustment, gradual guards, strict/generic closure dispatch, Titan variadic structs, and flexible results.
- Direct C and C-function-pointer calls use C argument conversions, explicit C varargs, enum certification, mutation/spill annotations, and C code generation. They never use closure adjustment or Lua callable dispatch.

Replace `c_function_as_function_type` and other temporary `Type.Function` projections in ordinary calls and generic-for elaboration with that shared signature view.

### 3. Preserve C function-pointer behavior

- Keep `Type.CPointer(Type.CFunction)` callable through the existing C-pointer call path.
- Replace `function_type_as_c_pointer` with an explicit decay from a direct C declaration to a compatible C pointer.
- Contextual decay must retain the exact authoritative C signature, including typedef spelling, qualifiers, ABI, prototype style, and C `...`.
- Continue rejecting a direct FFI function in every ordinary first-class-value context.
- Do not add Titan-to-C callback adaptation; that remains a separate parked feature.

### 4. Simplify relations and FFI plumbing

- Make `types.callable_adjustment`, `consistent`, gradual guards, and callable serialization reason only about `Type.Function`; remove the defensive C-vararg special case.
- Simplify `Type.Function` equality to Titan/Lua callable shape. Keep C signature equality entirely in `Type.CFunction`/C declaration compatibility.
- Update C-origin/include traversal, `cprobe`, redeclaration batching, declaration-array views, and composite merging to traverse `Type.CFunction` directly instead of unwrapping `_c_function`.
- Ensure no generic relation turns `Type.CFunction` into `Type.Function` or vice versa. Direct function-to-pointer decay stays a checker-owned contextual action.

## Tests

Add focused coverage at the owning layers:

- `spec/foreigntypes_spec.lua`: direct function declarations convert to `Type.CFunction`; pointer declarations remain `Type.CPointer(Type.CFunction)`; origin, prototype, qualifier, and redeclaration information stays on the C graph.
- `spec/types_spec.lua`: Titan `Type.Function` has no C-vararg/declaration branch; C signatures compare through C rules; no callable adjustment exists between C and Titan function types.
- `spec/checker/c_ffi*_spec.lua`: fixed, void, non-void, enum-bearing, old-style/prototype, and C-variadic direct calls retain current diagnostics and plans; direct functions decay only in compatible C-pointer contexts and are rejected as Titan values.
- `spec/coder/c_ffi*_spec.lua`: direct and pointer calls preserve generated C spelling, explicit C varargs, return handling, and evaluation order.
- Generic-for compiler tests: both direct imported functions and C function pointers retain sentinel/close behavior without a `Type.Function` projection.
- Closure-adjustment specs: assert that only Titan/Lua `Type.Function` plans reach wrapper freezing and code generation.

Run the pure relation/FFI suites first, then the complete compiler group and `make test`. No ABI bump is expected unless the implementation unexpectedly changes a serialized public or native layout.

## Documentation

Update the implementation manuals for the checker type model and C FFI call lowering. The language surface should not change, but clarify the language manual if it currently describes direct C functions as first-class Titan function values.

## Non-goals

- No Titan-function-to-C-callback wrapper.
- No Lua closure representation for a C function pointer.
- No change to Titan `TitanVargX` input tails or flexible-result ABI.
- No general subtyping or broadening of callable adjustment.
- No ABI bump solely for an internal checker representation cleanup.
