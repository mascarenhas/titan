/* The browser playground compiler: one Lua state running the bundled Titan
 * compiler, with LPegLabel and Titan's support module as preloaded C
 * libraries. Its only caller is the paired titanc.mjs adapter. Requests and
 * replies are opaque byte strings the bundled titan-compiler/playground.lua
 * frames; this file only owns the state and moves bytes across the boundary.
 */
#include <stdlib.h>
#include <string.h>

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

extern int luaopen_titan(lua_State *L);
extern int titan_lpeglabel_open(lua_State *L);

/* The generated Lua chunk installing every bundled module as a preload
 * loader; it returns the request handler. */
static const char bundle[] = {
#embed "titanc-bundle.lua"
};

#define TITANC_EXPORT(name) __attribute__((export_name(name)))

static lua_State *state;

static int open_compiler(lua_State *L) {
    luaL_openlibs(L);
    luaL_getsubtable(L, LUA_REGISTRYINDEX, LUA_PRELOAD_TABLE);
    lua_pushcfunction(L, luaopen_titan);
    lua_setfield(L, -2, "titan");
    lua_pushcfunction(L, titan_lpeglabel_open);
    lua_setfield(L, -2, "lpeglabel");
    lua_pop(L, 1);
    if (luaL_loadbuffer(L, bundle, sizeof bundle, "=titanc") != LUA_OK) return lua_error(L);
    lua_call(L, 0, 1);
    lua_setfield(L, LUA_REGISTRYINDEX, "titanc.handler");
    return 0;
}

TITANC_EXPORT("titanc_alloc")
void *titanc_alloc(size_t size) {
    return malloc(size);
}

TITANC_EXPORT("titanc_free")
void titanc_free(void *block) {
    free(block);
}

/* Each call leaves its reply string on the stack, which keeps it alive
 * until the next call; `reply`/`length` borrow it. A nonzero status means
 * the reply is an error message rather than a framed reply. */
static int finish(int status, const char **reply, size_t *length) {
    if (lua_type(state, -1) == LUA_TSTRING) {
        *reply = lua_tolstring(state, -1, length);
    } else {
        *reply = "titanc: non-string result";
        *length = 25;
    }
    return status != LUA_OK;
}

static int fail(const char *message, const char **reply, size_t *length) {
    *reply = message;
    *length = strlen(message);
    return 1;
}

TITANC_EXPORT("titanc_open")
int titanc_open(const char **reply, size_t *length) {
    if (state != NULL) return fail("titanc: the compiler is already open", reply, length);
    state = luaL_newstate();
    if (state == NULL) return fail("titanc: cannot allocate a Lua state", reply, length);
    lua_pushcfunction(state, open_compiler);
    int status = lua_pcall(state, 0, 0, 0);
    if (status != LUA_OK) return finish(status, reply, length);
    *reply = "";
    *length = 0;
    return 0;
}

/* Copying the request into the state allocates, so it happens inside the
 * protected call. */
static int dispatch(lua_State *L) {
    const char *request = lua_touserdata(L, 1);
    size_t request_length = (size_t)lua_tointeger(L, 2);
    lua_getfield(L, LUA_REGISTRYINDEX, "titanc.handler");
    lua_pushlstring(L, request, request_length);
    lua_call(L, 1, 1);
    return 1;
}

TITANC_EXPORT("titanc_call")
int titanc_call(const char *request, size_t request_length, const char **reply, size_t *length) {
    if (state == NULL) return fail("titanc: the compiler is not open", reply, length);
    lua_settop(state, 0);
    lua_pushcfunction(state, dispatch);
    lua_pushlightuserdata(state, (void *)request);
    lua_pushinteger(state, (lua_Integer)request_length);
    return finish(lua_pcall(state, 2, 1, 0), reply, length);
}
