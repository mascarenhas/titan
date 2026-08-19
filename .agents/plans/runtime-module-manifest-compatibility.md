# Runtime Module Manifest Compatibility Check

When a Titan module imports another module through a DSO (dynamic import), the compiler extracts the imported module's type manifest at compile time and uses it to generate correct code. Previously, the generated runtime initialization only called `titan_check_abi` to verify that the compiler ABI version string matched, but did **not** verify that the full type/layout manifest embedded in the runtime DSO matched the manifest the importing module was compiled against. If the DSO was replaced with one having the same ABI version but different types (e.g. altered record fields, modified function signatures, or changed method layouts), the result was silent memory corruption or crashes.

This change embeds the compile-time serialized type manifest string of each dynamically imported module into the importing module's generated C code, and adds a runtime handshake (`titan_check_types`) that compares it against the `<mangled>_types` symbol exported by the loaded DSO.

---

## User Review & Decisions

1. **Error Message Form**: Uses a concise diagnostic identifying the provider file and mangled types symbol without dumping the raw serialized type string:
   ```text
   Titan compiled module 'provider.so' type manifest mismatch: the loaded provider 'provider_types' has a different module interface than the one this module was compiled against
   ```
2. **Execution Ordering**: `titan_check_types` executes immediately after `titan_check_abi` in the `loadmods` initialization block using the same DSO handle, ensuring ABI and manifest verification occur before any native entry symbols (`init`, functions, methods) are resolved or called.
3. **Scope**: Applies to dynamic imports loaded from a `.so` at runtime. Static/source imports are co-compiled within the same executable/provider closure and are guarded by the stronger source provider identity token (`source_check`).

---

## Changes

### 1. Runtime Library

#### `titan-runtime/titan.h`
Declared `titan_check_types`:
```c
LUAI_FUNC void titan_check_types(lua_State *L, void *lib, const char *sym,
                                 const char *file, const char *expected);
```

#### `titan-runtime/titan.c`
Implemented `titan_check_types`:
- Resolves `<mangled>_types` from the library handle via `dlsym`.
- If missing, aborts with `"Titan compiled module '%s' is missing types symbol '%s': %s"`.
- Calls the function to get the runtime type manifest string.
- Compares the returned string with the compile-time `expected` string literal via `strcmp`.
- If different, aborts with `"Titan compiled module '%s' type manifest mismatch: the loaded provider '%s' has a different module interface than the one this module was compiled against"`.

```c
void titan_check_types(lua_State *L, void *lib, const char *sym,
                       const char *file, const char *expected) {
    typedef int (*titan_types_fn)(lua_State *);
    void *raw;
    titan_types_fn fn;
    int top = lua_gettop(L);
    int nresults;
    const char *actual;
    dlerror();  /* clear stale error */
    raw = dlsym(lib, sym);
    if (raw == NULL) {
        const char *err = dlerror();
        luaL_error(L,
            "Titan compiled module '%s' is missing types symbol '%s': %s",
            file, sym, err ? err : "symbol not found");
    }
    fn = titan_cast_func(titan_types_fn, raw);
    nresults = fn(L);
    if (nresults != 1 || !lua_isstring(L, -1)) {
        lua_settop(L, top);
        luaL_error(L,
            "Titan compiled module '%s' has an invalid types marker '%s'",
            file, sym);
    }
    actual = lua_tostring(L, -1);
    if (strcmp(actual, expected) != 0) {
        luaL_error(L,
            "Titan compiled module '%s' type manifest mismatch: "
            "the loaded provider '%s' has a different module interface "
            "than the one this module was compiled against",
            file, sym);
    }
    lua_settop(L, top);
}
```

---

### 2. Code Generator

#### `titan-compiler/coder/module.lua`
In `import_module`:
- Retrieves the declared (un-erased) type if present (`rawget(node, "_declared_type") or node._type`) to ensure generic modules match their published declared interface manifest.
- Serializes the expected type via `types.serialize(expected_type)`.
- Generates the `titan_check_types` call following `titan_check_abi`:

```lua
    if dynamic then
        local file = node._type.file
        local expected_type = rawget(node, "_declared_type") or node._type
        local expected_types = types.serialize(expected_type)
        table.insert(loadmods, render([[
            void *$HANDLE = loadlib(L, $FILE);
            titan_check_abi(L, $HANDLE, "$ABI", $FILE);
            titan_check_types(L, $HANDLE, "$TYPES", $FILE, $EXPECTED);
        ]], {
            HANDLE = mprefix .. "handle",
            FILE = c_string_literal(file),
            ABI = mprefix .. "abi",
            TYPES = mprefix .. "types",
            EXPECTED = c_string_literal(expected_types),
        }))
```

---

### 3. Documentation

Updated implementation manuals to document `titan_check_types` alongside `titan_check_abi`:
- `doc/implementation/multi-module-libraries.md`
- `doc/implementation/lua-interop-internals.md`
- `doc/implementation/driver.md`
- `doc/implementation/error-handling.md`

---

### 4. Tests

#### Single `.so` Imports (`spec/coder/so_import_spec.lua`)
- `aborts when the loaded .so has an incompatible type manifest`: compiles a consumer against provider v1, recompiles provider v2 with altered types, and verifies consumer aborts with `"type manifest mismatch"`.
- `aborts when the loaded .so is missing the types symbol`: loads a DSO without `_types` symbol and verifies abort with `"missing types symbol"`.

#### Multi-Module Single-DSO Imports (`spec/coder/multi_module_libraries_spec.lua`)
- Verified generated C emits separate `titan_check_types` calls for `pkg_left_types` and `pkg_right_types` against the shared `pkg.so` handle.
- `aborts when a multi-module DSO has a manifest mismatch for one of its members`: verifies that recompiling `pkg.so` with only `pkg.left` modified causes consumers importing from `pkg.so` to detect the mismatch on `pkg_left_types` and abort.

---

## Verification Results

- `busted spec/coder/so_import_spec.lua`: 23/23 tests passed.
- `busted spec/coder/multi_module_libraries_spec.lua`: 33/33 tests passed.
- `busted spec/abi_spec.lua`: 5/5 tests passed.
- Cross-module coder specs (`generics_spec.lua`, `unions_spec.lua`, `static_compiled_modules_spec.lua`, `multi_module_path_runtime_spec.lua`, `multi_module_grouping_spec.lua`, `static_dynamic_facade_spec.lua`, `folder_modules_spec.lua`, `so_trace_names_spec.lua`, `bound_methods_spec.lua`): 77/77 tests passed.
- Native standard library test suite (`make titan-stdlib-test-run`): 197/197 tests passed.
