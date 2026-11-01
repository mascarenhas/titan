#include <assert.h>
static int fail_copy;
void *__real_malloc(size_t size);
void *__wrap_malloc(size_t size) {
    if (fail_copy && size == 433) {
        assert(fputs("copy-allocator", stdout) >= 0);
        return NULL;
    }
    return __real_malloc(size);
}
static int titan_browser_worker(lua_State *L) {
    unsigned char message[433];
    static char buffer[BUFSIZ];
    assert(setvbuf(stdout, buffer, _IOFBF, sizeof buffer) == 0);
    memset(message, 'q', sizeof message);
    message[1] = 0;
    lua_pushlstring(L, (const char *)message, sizeof message);
    fail_copy = 1;
    return lua_error(L);
}
