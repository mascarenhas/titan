#include <stdio.h>
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
#include "lobject.h"
#include "minicoro.h"
#include "titan_lpeglabel.h"

static TValue tag;
static int steps;
static mco_result yielded;

static void run_coroutine(mco_coro *co) {
    steps = 1;
    yielded = mco_yield(co, &tag);
    steps = 2;
}

int main(void) {
    lua_State *L = luaL_newstate();
    mco_runtime runtime = {0};
    mco_coro *co = NULL;
    mco_desc descriptor = mco_desc_init(run_coroutine, 0);
    if (L == NULL) return 1;
    luaL_openlibs(L);
    lua_pushcfunction(L, titan_lpeglabel_open);
    lua_call(L, 0, 1);
    lua_setglobal(L, "private_peg");
    if (luaL_dostring(L,
            "assert(private_peg.match(private_peg.P('a')^1, 'aaa') == 4)")) {
        fprintf(stderr, "%s\n", lua_tostring(L, -1));
        return 2;
    }
    setivalue(&tag, 17);
    descriptor.runtime = &runtime;
    if (mco_create(&co, &descriptor) != MCO_SUCCESS) return 3;
    if (mco_resume(co, &tag) != MCO_SUCCESS || steps != 1) return 4;
    if (mco_resume(co, &tag) != MCO_SUCCESS || steps != 2 ||
            yielded != MCO_SUCCESS) return 5;
    if (mco_destroy(co) != MCO_SUCCESS || runtime.current_co != NULL) return 6;
    lua_close(L);
    puts("Windows runtime SDK: shared Lua, private PEG, explicit-runtime coroutine yield/resume passed");
    return 0;
}
