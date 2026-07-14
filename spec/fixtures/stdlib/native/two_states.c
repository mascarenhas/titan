#include <stdio.h>

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

static int run_chunk(lua_State *L, const char *label, const char *source) {
    int status = luaL_loadstring(L, source);
    if (status == LUA_OK)
        status = lua_pcall(L, 0, 0, 0);
    if (status != LUA_OK) {
        const char *message = lua_tostring(L, -1);
        fprintf(stderr, "%s: %s\n", label,
                message != NULL ? message : "non-string Lua error");
        lua_pop(L, 1);
        return 0;
    }
    return 1;
}

static lua_State *new_state(const char *label) {
    lua_State *L = luaL_newstate();
    if (L == NULL) {
        fprintf(stderr, "%s: luaL_newstate failed\n", label);
        return NULL;
    }
    luaL_openlibs(L);
    return L;
}

int main(void) {
    static const char setup_first[] =
        "state_token = 101\n"
        "state_started = false\n"
        "state_uv = require 'titan.uv'\n"
        "state_timer = require 'titan.timer'\n"
        "state_task = state_uv.run(function()\n"
        "  state_started = true\n"
        "  state_timer.yield()\n"
        "  return state_token\n"
        "end)\n"
        "assert(not state_started)\n"
        "assert(state_task:status() == 'ready')\n";
    static const char setup_second[] =
        "state_token = 202\n"
        "state_started = false\n"
        "state_uv = require 'titan.uv'\n"
        "state_timer = require 'titan.timer'\n"
        "state_task = state_uv.run(function()\n"
        "  state_started = true\n"
        "  state_timer.yield()\n"
        "  return state_token\n"
        "end)\n"
        "assert(not state_started)\n"
        "assert(state_task:status() == 'ready')\n";
    static const char drive_second[] =
        "assert(not state_started)\n"
        "state_uv.loop()\n"
        "assert(state_started)\n"
        "assert(state_task:join() == 202)\n";
    static const char first_still_pending[] =
        "assert(not state_started)\n"
        "assert(state_task:status() == 'ready')\n";
    static const char drive_first[] =
        "state_uv.loop()\n"
        "assert(state_started)\n"
        "assert(state_task:join() == 101)\n"
        "local again = state_uv.run(function()\n"
        "  state_timer.yield()\n"
        "  return 303\n"
        "end)\n"
        "state_uv.loop()\n"
        "assert(again:join() == 303)\n";
    lua_State *first = new_state("first state");
    lua_State *second = new_state("second state");
    int ok = first != NULL && second != NULL;

    if (ok) ok = run_chunk(first, "set up first state", setup_first);
    if (ok) ok = run_chunk(second, "set up second state", setup_second);
    if (ok) ok = run_chunk(second, "drive second state", drive_second);
    if (ok) ok = run_chunk(first, "check first state", first_still_pending);

    if (second != NULL) {
        lua_close(second);
        second = NULL;
    }

    if (ok) ok = run_chunk(first, "drive first state", drive_first);
    if (first != NULL) lua_close(first);
    if (!ok) return 1;

    return 0;
}
