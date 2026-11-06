#include <assert.h>
static int titan_browser_worker(lua_State *L) {
    unsigned char message[433];
    static char buffer[BUFSIZ];
    assert(setvbuf(stdout, buffer, _IOFBF, sizeof buffer) == 0);
    memset(message, 'q', sizeof message);
    message[1] = 0;
    lua_pushlstring(L, (const char *)message, sizeof message);
    return lua_error(L);
}
