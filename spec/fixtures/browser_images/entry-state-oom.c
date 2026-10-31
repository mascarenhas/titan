#include <assert.h>
static void *fail_state_allocation(void *ud, void *pointer, size_t old_size, size_t new_size) {
    (void)ud; (void)pointer; (void)old_size;
    assert(new_size > 0);
    assert(fputs("state-allocator", stdout) >= 0);
    return NULL;
}
lua_State *__wrap_luaL_newstate(void) {
    static char buffer[BUFSIZ];
    assert(setvbuf(stdout, buffer, _IOFBF, sizeof buffer) == 0);
    return lua_newstate(fail_state_allocation, NULL, 0);
}
static int titan_browser_worker(lua_State *L) {
    lua_pushinteger(L, 0);
    return 1;
}
