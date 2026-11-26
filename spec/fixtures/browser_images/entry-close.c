#include <assert.h>
#include <titan/browser.h>

/* Publishes raw entry probes to the harness (fixture-imports.mjs). */
TITAN_WASM_IMPORT("publish_absent_module_probe") void publish_absent_module_probe(void);

static int close_tail(lua_State *L) {
    static const unsigned char out[] = {67, 0, 255};
    static const unsigned char err[] = {68, 0, 254};
    (void)L;
    assert(fwrite(out, 1, sizeof out, stdout) == sizeof out);
    assert(fwrite(err, 1, sizeof err, stderr) == sizeof err);
    return 0;
}
static int titan_browser_worker(lua_State *L) {
    static char out_buffer[BUFSIZ], err_buffer[BUFSIZ];
    assert(setvbuf(stdout, out_buffer, _IOFBF, sizeof out_buffer) == 0);
    assert(setvbuf(stderr, err_buffer, _IOFBF, sizeof err_buffer) == 0);
    lua_newuserdatauv(L, 1, 0);
    lua_newtable(L);
    lua_pushcfunction(L, close_tail);
    lua_setfield(L, -2, "__gc");
    lua_setmetatable(L, -2);
    lua_setfield(L, LUA_REGISTRYINDEX, "browser-entry-finalizer");
    publish_absent_module_probe();
    lua_pushinteger(L, (lua_Integer)UINT64_C(0x1ffffffff));
    return 1;
}
