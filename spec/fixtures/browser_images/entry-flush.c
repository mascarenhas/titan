#include <assert.h>
#include <errno.h>
#include <emscripten.h>
/* Interpose libc's flush boundary without an Emscripten filesystem device. */
EM_JS(void, observe_flush, (int stream), {
    Module['titanBrowserBridge'].options.bindings.fixtureDrains(stream);
});
static int flush_failures, observed_flushes;
int __real_fflush(FILE *file);
int __wrap_fflush(FILE *file) {
    int status = __real_fflush(file);
    int stream = file == stdout ? 1 : file == stderr ? 2 : 0;
    if (!(observed_flushes & stream)) return status;
    observed_flushes &= ~stream;
    observe_flush(stream);
    if (!(flush_failures & stream)) return status;
    errno = EIO;
    return EOF;
}
static int titan_browser_worker(lua_State *L) {
    struct titan_browser_arguments *args = lua_touserdata(L, 1);
    assert(args->argc == 1 && args->lengths[0] == 1);
    int failures = args->argv[0][0];
    flush_failures = failures;
    static char out_buffer[BUFSIZ], err_buffer[BUFSIZ];
    assert(setvbuf(stdout, out_buffer, _IOFBF, sizeof out_buffer) == 0);
    assert(setvbuf(stderr, err_buffer, _IOFBF, sizeof err_buffer) == 0);
    assert(fputs("out-tail", stdout) >= 0);
    assert(fputs("err-tail", stderr) >= 0);
    observed_flushes = 3;
    if (failures & 4) {
        lua_pushliteral(L, "original failure");
        return lua_error(L);
    }
    lua_pushinteger(L, 37);
    return 1;
}
