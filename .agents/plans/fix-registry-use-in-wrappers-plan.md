# Eliminate Lua Registry Lookups in Titan Adapter Functions

## Overview

Callable adapters and interface method adapters in Titan previously pulled type tags (Array metatables, Nominal metatables, and Owned C metatables) from the global Lua registry using `titan_registry_get_string_table` and `titan_array_cached_metatables` in `_interface_adapter_identity_prelude`. This violated Titan compiler invariants: adapters are executed on the fast path for first-class function calls and interface method dispatches, where expensive string interning and global registry hash table lookups must never happen.

The root cause was an inconsistent ownership invariant for the `_mod` parameter passed to adapters:
1. For callable adapters, the wrapper closure copied `_ca_source->upvalue[0]` (the wrapped function's module) to `_ca_wrapper->upvalue[0]`, causing the fast-path caller to pass the wrapped module rather than the module owning the adapter.
2. For interface method adapters, the interface wrapper `Udata` stored `concrete_module` in `uv[0]`, passing the concrete module rather than the module where the cast to the interface took place.
3. Because adapters received the wrong module as `_mod`, they could not read their own module's type identity slots (`_mod->uv[slot]`) and resorted to looking up metatables in the global Lua registry.

This refactoring restored the proper compiler invariant: **`_mod` for any generated function or adapter is always the module that function/adapter belongs to**. With this invariant in place, all type tags/metatables are resolved statically to module uservalue slots `_mod->uv[slot]`, completely eliminating `_interface_adapter_identity_prelude`, `titan_registry_get_string_table`, and dynamic registry queries from adapter code paths.

---

## Architectural Invariants & Key Mechanisms

### 1. Callable Adapters
- **Creation (`_emit_callable_adapter_value` in [coder/calls.lua](file:///home/mascarenhas/Code/titan/titan-compiler/coder/calls.lua))**:
  - `_ca_wrapper->upvalue[0]` is initialized with `_mod` (the module owning the cast and the adapter).
  - `_ca_wrapper->upvalue[1]` = `$TARGET_TAG`.
  - `_ca_wrapper->upvalue[2]` = `$TARGET_ADAPTER` (native entry).
  - `_ca_wrapper->upvalue[3]` = `TITAN_FUNCTION_CLOSURE_BRAND`.
  - `_ca_wrapper->upvalue[nup - 2]` = `_ca_source` (the wrapped source closure).
  - `_ca_wrapper->upvalue[nup - 1]` = `$TARGET_STRICT` (strict entry).
- **Fast Path Call Site ([coder/calls.lua](file:///home/mascarenhas/Code/titan/titan-compiler/coder/calls.lua))**:
  - `_vc_mod = uvalue(&_vc_callee->upvalue[0]);` -> passes `_vc_mod` (which is `_ca_wrapper->upvalue[0]`, the adapter's module).
  - `_vc_fp(L, _vc_mod, _vc_callee, ...);`
- **Native Adapter Body (`_emit_callable_adapter` in [coder/declarations.lua](file:///home/mascarenhas/Code/titan/titan-compiler/coder/declarations.lua))**:
  - `_mod` is the adapter's module.
  - All conversions, gradual guards, injections, and array/nominal/owned-C metatables read directly from `_mod->uv[slot]`.
  - To call the wrapped function, it extracts:
    - `_ia_source = clCvalue(&_fn->upvalue[_fn->nupvalues - 2]);`
    - `_ia_source_mod = uvalue(&_ia_source->upvalue[0]);`
    - `_ia_source_fp = titan_cast_func(..., pvalue(&_ia_source->upvalue[2]));`
    - Invokes `_ia_source_fp(L, _ia_source_mod, _ia_source, ...);`
- **Strict Entry (`genluaentry` in [coder/declarations.lua](file:///home/mascarenhas/Code/titan/titan-compiler/coder/declarations.lua))**:
  - `Udata *_mod = uvalue(&_fn->upvalue[0]);` recovers the adapter's module directly without calling `init(L)`.

### 2. Interface Wrappers & Method Adapters
- **Interface Wrapper Layout (`_render_interface_wrapper_allocation` in [coder/interfaces.lua](file:///home/mascarenhas/Code/titan/titan-compiler/coder/interfaces.lua))**:
  - `uv[0]`: `_mod` (the module creating the interface wrapper, where the cast took place).
  - `uv[1]`: `concrete_value` (the concrete record/union `_self`).
  - `uv[2 + i]`: field snapshot `i`.
  - `udatamem`: `vtable` (`pair.id`).
- **Interface Method Call Site ([coder/calls.lua](file:///home/mascarenhas/Code/titan/titan-compiler/coder/calls.lua), [coder/declarations.lua](file:///home/mascarenhas/Code/titan/titan-compiler/coder/declarations.lua), [coder/module.lua](file:///home/mascarenhas/Code/titan/titan-compiler/coder/module.lua))**:
  - Passes `(L, uvalue(&wrapper->uv[0].uv), NULL, uvalue(&wrapper->uv[1].uv), ...)`.
  - Parameter 2 (`_mod`) is the adapter module (`wrapper->uv[0]`).
  - Parameter 4 (`_self`) is the concrete record/union (`wrapper->uv[1]`).
- **Interface VTable Slots & Method Adapters (`coder._interface_pair` in [coder/interfaces.lua](file:///home/mascarenhas/Code/titan/titan-compiler/coder/interfaces.lua) & [checker/interfaces.lua](file:///home/mascarenhas/Code/titan/titan-compiler/checker/interfaces.lua))**:
  - `policy.interface_coercion` sets `implementation.cast_module = policy.visibility`.
  - `make_interface_adapter` generates an adapter when `mapping.exact == false` OR `owner_module ~= cast_module`.
  - If `mapping.exact == true` AND `owner_module == cast_module`, `slot_kind = "exact"`, and the vtable slot points directly to `method_name(mapping.concrete)`.
- **Interface Method Adapter Body (`_emit_interface_adapter` in [coder/interfaces.lua](file:///home/mascarenhas/Code/titan/titan-compiler/coder/interfaces.lua))**:
  - `_mod` parameter is the casting module (`tlcontext._mod`).
  - All metatable / type tag expressions read directly from `_mod->uv[slot]`.
  - To call the concrete method:
    - `concrete_mod = coder._interface_owner_module_expr(ctx, adapter.concrete_owner)` (which generates `_mod` if same module, or `uvalue(&_mod->uv[ctx.modules[owner_module]].uv)` if imported).
    - Invokes `concrete_method(L, concrete_mod, NULL, _self, ...)`.
- **Dynamic Interface Casts**:
  - Dynamic discovery witness CClosure retains `upvalue[0] = _mod` (the module that registered the witness).
  - Wrapper allocator is invoked with that module's `_mod`, populating `uv[0]` with that module and the matching vtable.

### 3. Tag Resolution in `coder/names.lua`
- `array_metatable_kind`: returns `hvalue(&_mod->uv[slot].uv)`.
- `_nominal_metatable_expr`: returns `hvalue(&_mod->uv[type2metatable(ctx, typ)].uv)`.
- `_owned_c_metatable_expr`: returns `hvalue(&_mod->uv[owned_c_metatable(ctx, typ)].uv)`.
- Removed `ctx.interface_adapter_*_metatables` override maps and `_interface_adapter_identity_prelude`.

---

## Implemented Changes

### Compiler Coder & Checker
- **[titan-compiler/coder/names.lua](file:///home/mascarenhas/Code/titan/titan-compiler/coder/names.lua)**:
  - Simplified `array_metatable_kind`, `_nominal_metatable_expr`, and `_owned_c_metatable_expr` to directly emit `hvalue(&_mod->uv[slot].uv)`.
  - Exported `coder.array_metatable_kind` and `coder.owned_c_metatable_key`.
- **[titan-compiler/coder/interfaces.lua](file:///home/mascarenhas/Code/titan/titan-compiler/coder/interfaces.lua)**:
  - Removed `_interface_adapter_identity_prelude`, `_interface_adapter_identity_inventory`, `_interface_adapter_collect_identity`, and `$IDENTITIES`.
  - In `_emit_interface_adapter_call`, emitted `concrete_mod = coder._interface_owner_module_expr(ctx, adapter.concrete_owner)` and passed `concrete_mod` to `method_name(adapter.concrete_method)`.
  - In `_render_interface_wrapper_allocation`, initialized `uv[0]` with `_mod` (the casting/allocating module).
  - In `_interface_pair`, checked `mapping.slot_kind == "exact"`.
- **[titan-compiler/coder/declarations.lua](file:///home/mascarenhas/Code/titan/titan-compiler/coder/declarations.lua)**:
  - In `genluaentry`, standardized strict entry module setup to `Udata *_mod = uvalue(&_fn->upvalue[0]);`.
- **[titan-compiler/coder/calls.lua](file:///home/mascarenhas/Code/titan/titan-compiler/coder/calls.lua)**:
  - In `_emit_callable_adapter_value`, set `_ca_wrapper->upvalue[0] = _mod` when `_ca_i == 0`.
- **[titan-compiler/cpreamble.lua](file:///home/mascarenhas/Code/titan/titan-compiler/cpreamble.lua)**:
  - Removed unused `titan_registry_get_string_table`.
- **[titan-compiler/checker/interfaces.lua](file:///home/mascarenhas/Code/titan/titan-compiler/checker/interfaces.lua)**:
  - In `policy.interface_coercion`, stored `implementation.cast_module = policy.visibility`.
  - In `make_interface_adapter`, generated an adapter when `owner_module ~= cast_module`.

### Specs & Test Suites
- **[spec/coder/adapter_registry_elimination_spec.lua](file:///home/mascarenhas/Code/titan/spec/coder/adapter_registry_elimination_spec.lua)**:
  - Added 4 test cases testing callable and interface adapter module invariants, registry lookup elimination, tag resolution via `_mod->uv`, and cross-module dispatch.
- **[spec/support/ci_compiler_test_groups.txt](file:///home/mascarenhas/Code/titan/spec/support/ci_compiler_test_groups.txt)**:
  - Registered `1 spec/coder/adapter_registry_elimination_spec.lua 1.223` in Shard 1 in alphabetical order.
- **[spec/libuv_build_spec.lua](file:///home/mascarenhas/Code/titan/spec/libuv_build_spec.lua)**:
  - Updated shard counts `{ 29, 26, 27, 28 }` and assigned count `110`.
- **[spec/checker/interfaces_spec.lua](file:///home/mascarenhas/Code/titan/spec/checker/interfaces_spec.lua)** & **[spec/coder/interfaces_spec.lua](file:///home/mascarenhas/Code/titan/spec/coder/interfaces_spec.lua)**:
  - Updated provenance assertions and unit test checks to align with the new `_mod` invariant.

---

## Verification & Walkthrough Results

1. **Compilation & Installation**:
   - `luarocks make` with the then-active rockspec built and installed cleanly to `/tmp/titan-mascarenhas-const93` and `.local-builds/titan-mascarenhas-const93`.
2. **Targeted Spec Execution**:
   - `spec/coder/adapter_registry_elimination_spec.lua`: 4 successes / 0 failures / 0 errors.
   - `spec/checker/interfaces_spec.lua`: 55 successes / 0 failures.
   - `spec/coder/interfaces_spec.lua`: 42 successes / 0 failures.
   - `spec/libuv_build_spec.lua`: 49 successes / 0 failures.
3. **Full Suite (`make rock-test`)**:
   - 8 runtime/packaging specs passed serially.
   - All 4 compiler test shards passed in parallel:
     - Shard 1: 527 tests passed.
     - Shard 2: 549 tests passed.
     - Shard 3: passed.
     - Shard 4: 865 tests passed.
   - 22-root aggregate native stdlib test executable passed all 197 tests.
