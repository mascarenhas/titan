-- Fixed C translation-unit prefix shared by generated modules and compiler
-- probes. Foreign imports are emitted immediately after this block in both
-- places, so the configured headers see the same Lua/Titan declarations and
-- macro state during validation and production compilation.
local cpreamble = {}

-- One inventory feeds both emitted module includes and certification. Runtime
-- includes are also closed over by the probe, without changing module macro
-- visibility merely to certify entrypoint/FFI support.
cpreamble.include_constants = {
    { "<stdlib.h>", module = true },
    { "<stddef.h>", module = true },
    { "<string.h>", module = true },
    { "<math.h>", module = true },
    { '"luaconf.h"', module = true },
    { '"lauxlib.h"', module = true },
    { '"lstate.h"', module = true },
    { '"lgc.h"', module = true },
    { '"ltable.h"', module = true },
    { '"ltm.h"', module = true },
    { '"lfunc.h"', module = true },
    { '"lstring.h"', module = true },
    { '"lvm.h"', module = true },
    { '"lobject.h"', module = true },
    { '"ldo.h"', module = true },
    { '"titan.h"', module = true },
    { '"lua.h"' },
    { '"lualib.h"' },
    { '<titan/ffi.h>' },
    { '<windows.h>', condition = "defined(_WIN32)" },
    { '<wchar.h>', condition = "defined(_WIN32)" },
    { '<unistd.h>', condition = "!defined(_WIN32)" },
    { '<limits.h>', condition = "!defined(_WIN32)" },
    { '<mach-o/dyld.h>', condition = "defined(__APPLE__)" },
}

function cpreamble.includes(all)
    local lines = {}
    for _, include in ipairs(cpreamble.include_constants) do
        if all or include.module then
            if include.condition then lines[#lines + 1] = "#if " .. include.condition end
            lines[#lines + 1] = "#include " .. include[1]
            if include.condition then lines[#lines + 1] = "#endif" end
        end
    end
    return table.concat(lines, "\n")
end

cpreamble.fixed_includes = cpreamble.includes(false)
cpreamble.certification_includes = cpreamble.includes(true) .. "\n"

local function fixed_prefix(defline)
    return cpreamble.fixed_includes .. [[

]] .. defline .. [[static TITAN_UNUSED inline int titan_errfunc_is_errorhandler(lua_State *L) {
    if (L->errfunc == 0) return 0;
    StkId errfunc = restorestack(L, L->errfunc);
    TValue *v = s2v(errfunc);
    return ttislcf(v) && fvalue(v) == errorhandler;
}

/*
 * Read a string-keyed registry entry without allocating or using the Lua stack.
 * The caller supplies an already-rooted key, including on low-memory recovery
 * paths where interning even a fixed key string could raise another error.
 */
]] .. defline .. [[static TITAN_UNUSED inline lu_byte titan_registry_get_string(
        lua_State *L, TString *registry_key, TValue *result) {
    setnilvalue(result);
    lua_assert(ttistable(&G(L)->l_registry));
    return luaH_getstr(
        hvalue(&G(L)->l_registry), registry_key, result);
}


/*
 * Set a string-keyed registry entry using an already-rooted key. The caller
 * must also keep a collectable value traced across this call. Copy the value
 * before a resize can relocate its source StkId. For a missing non-nil entry,
 * resize only when the hash has no genuinely free node. The insertion roots
 * the key before HARDMEMTESTS can force an emergency collection.
 * Clearing an entry never allocates, even when the key is absent.
 * This helper never reads or changes L->top.
 */
]] .. defline .. [[static TITAN_UNUSED inline void titan_registry_set_string(
        lua_State *L, TString *registry_key, const TValue *value) {
    TValue value_copy = *value;
    TValue key_value;
    Table *registry = hvalue(&G(L)->l_registry);
    int hres = luaH_psetstr(registry, registry_key, &value_copy);
    if (hres == HNOTFOUND && !ttisnil(&value_copy)) {
        unsigned node_count = allocsizenode(registry);
        int has_free_node = 0;
        for (unsigned i = 0; i < node_count; i++) {
            if (keyisnil(gnode(registry, i))) {
                has_free_node = 1;
                break;
            }
        }
        if (!has_free_node) {
            luaH_resize(L, registry, registry->asize, node_count + 1u);
            hres = luaH_psetstr(registry, registry_key, &value_copy);
            lua_assert(hres == HOK || hres == HNOTFOUND);
        }
    }
    if (hres != HOK) {
        setsvalue(L, &key_value, registry_key);
        luaH_finishset(L, registry, &key_value, &value_copy, hres);
    }
    invalidateTMcache(registry);
    luaC_barrierback(L, obj2gco(registry), &value_copy);
}

/*
 * Generated code frequently reserves stack slots before writing through
 * L->top.p directly. Use Lua's internal raising growth path and extend the
 * current frame limit exactly as lua_checkstack would, without crossing the
 * public stack API.
*/
]] .. defline .. [[static TITAN_UNUSED inline void titan_ensure_stack(lua_State *L, int slots) {
    luaD_checkstack(L, slots);
    if (L->ci->top.p < L->top.p + slots)
        L->ci->top.p = L->top.p + slots;
}

/*
 * Allocate a raw full-userdata object whose header the caller initializes.
 * This is gco2u(luaC_newobj(...)) without check_exp: under LUAI_ASSERT
 * check_exp evaluates its operand twice and would allocate a second, never
 * initialized object. Without LUAI_ASSERT the expansion is exactly gco2u's,
 * so ordinary builds generate the same code at every optimization level.
*/
#define titan_new_udata_object(L, size) \
    cast(Udata *, luaC_newobj((L), LUA_VUSERDATA, (size)))]]
end

cpreamble.fixed_prefix = fixed_prefix("")
-- Every emitted translation unit defines TITAN_GENERATED_C_FILE to its own
-- generated filename, so the shared fixed-prefix helpers name the generated C
-- rather than inheriting the preceding definition's `#line`.
cpreamble.definition_prefix = fixed_prefix("#line 1 TITAN_GENERATED_C_FILE\n")

cpreamble.after_foreign_imports = [[#if defined(__GNUC__) || defined(__clang__)
#define TITAN_SOURCE_LOCAL __attribute__((visibility("hidden")))
#else
#define TITAN_SOURCE_LOCAL
#endif

#ifdef __clang__
#pragma clang diagnostic ignored "-Wunused-function"
#pragma clang diagnostic ignored "-Wparentheses-equality"
#endif]]

return cpreamble
