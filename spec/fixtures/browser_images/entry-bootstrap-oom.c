#include <assert.h>
static lua_Alloc original_allocator;
static void *original_userdata;
static int bootstrap_allocation_failed;
static void *fail_bootstrap_allocation(void *ud, void *pointer, size_t old_size, size_t new_size) {
    (void)ud;
    if (new_size > 0) return NULL;
    return original_allocator(original_userdata, pointer, old_size, new_size);
}
void __real_luaL_openselectedlibs(lua_State *L, int load, int preload);
void __wrap_luaL_openselectedlibs(lua_State *L, int load, int preload) {
    original_allocator = lua_getallocf(L, &original_userdata);
    assert(fputs("bootstrap-allocator", stdout) >= 0);
    bootstrap_allocation_failed = 1;
    lua_setallocf(L, fail_bootstrap_allocation, NULL);
    __real_luaL_openselectedlibs(L, load, preload);
    assert(!"library bootstrap unexpectedly survived allocation failure");
}
int __real_lua_pcallk(lua_State *L, int arguments, int results, int handler, lua_KContext context, lua_KFunction continuation);
int __wrap_lua_pcallk(lua_State *L, int arguments, int results, int handler, lua_KContext context, lua_KFunction continuation) {
    int status = __real_lua_pcallk(L, arguments, results, handler, context, continuation);
    if (bootstrap_allocation_failed) {
        lua_setallocf(L, original_allocator, original_userdata);
        bootstrap_allocation_failed = 0;
        assert(status != LUA_OK);
    }
    return status;
}
static int titan_browser_worker(lua_State *L) {
    static char buffer[BUFSIZ];
    assert(setvbuf(stdout, buffer, _IOFBF, sizeof buffer) == 0);
    luaL_openlibs(L);
    lua_pushinteger(L, 0);
    return 1;
}
