#include <assert.h>
static int fail_copy;
static void *entry_copy_allocate(size_t size) {
    if (fail_copy && size == 433) {
        assert(fputs("copy-allocator", stdout) >= 0);
        return NULL;
    }
    return malloc(size);
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
/* Interpose only the generated entry's later copy, not the exported host
 * allocator. This keeps the real allocation-failure branch independent of
 * linker wrapping and of runtime libraries' incidental malloc references. */
#define malloc entry_copy_allocate
