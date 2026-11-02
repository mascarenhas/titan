/* Adapter-unit fixture: real Lua CallInfos and runtime errorhandler, with the
 * Node test supplying synthetic captured records/map identity at the JS edge. */
#include "titan.h"

static char filter_trace[4096];
static int filter_status;

const char *titan_browser_trace_identity(void) {
    return "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
}

static int filter_inner_titanentry_lua(lua_State *L) {
    return luaL_error(L, "filter case");
}

static int filter_outer_titanentry_lua(lua_State *L) {
    static const char chunk[] =
        "local function between()\n"
        "  local result = inner()\n"
        "  return result\n"
        "end\n"
        "local result = between()\n"
        "return result\n";
    if (luaL_loadbuffer(L, chunk, sizeof(chunk) - 1, "@filter-wrapper.lua") != LUA_OK)
        return lua_error(L);
    lua_call(L, 0, 0);
    return 0;
}

const char *trace_filter_case(void) {
    lua_State *L = luaL_newstate();
    const char *trace;
    if (L == NULL) return "cannot create fixture state";
    lua_newtable(L);
    lua_pushcfunction(L, filter_inner_titanentry_lua);
    lua_pushboolean(L, 1);
    lua_rawset(L, -3);
    lua_pushcfunction(L, filter_outer_titanentry_lua);
    lua_pushboolean(L, 1);
    lua_rawset(L, -3);
    lua_setfield(L, LUA_REGISTRYINDEX, TITAN_ENTRIES_KEY);
    lua_newtable(L);
    lua_pushliteral(L, "filter.inner");
    lua_setfield(L, -2, "filter_inner_native");
    lua_pushliteral(L, "filter.outer");
    lua_setfield(L, -2, "filter_outer_native");
    lua_setfield(L, LUA_REGISTRYINDEX, TITAN_NAMES_KEY);
    lua_pushcfunction(L, filter_inner_titanentry_lua);
    lua_setglobal(L, "inner");
    lua_pushcfunction(L, errorhandler);
    lua_pushcfunction(L, filter_outer_titanentry_lua);
    filter_status = lua_pcall(L, 0, 0, 1);
    lua_getfield(L, LUA_REGISTRYINDEX, TITAN_BACKTRACE_KEY);
    trace = lua_tostring(L, -1);
    snprintf(filter_trace, sizeof(filter_trace), "%s", trace ? trace : "missing trace");
    lua_close(L);
    return filter_trace;
}

int trace_filter_status(void) {
    return filter_status;
}
