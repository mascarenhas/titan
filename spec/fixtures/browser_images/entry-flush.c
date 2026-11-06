#include <assert.h>
#include <errno.h>
#include <emscripten.h>
EM_JS(void, configure_flush_devices, (int failures, int io_error), {
    const records = { order: [], stdout: [], stderr: [] };
    const publish = Module['titanBrowserBridge'].options.bindings?.fixtureDrains;
    if (publish) publish(records);
    for (const [index, name] of ['stdout', 'stderr'].entries()) {
        const device = FS.makedev(64, index);
        FS.registerDevice(device, {
            open(stream) { stream.seekable = false; },
            close() {},
            read() { return 0; },
            write(stream, buffer, offset, length) {
                records.order.push(name);
                records[name].push(...buffer.subarray(offset, offset + length));
                if (failures & (1 << index)) throw new FS.ErrnoError(io_error);
                return length;
            },
        });
        FS.mkdev('/dev/browser-entry-' + name, 438, device);
    }
});
static int titan_browser_worker(lua_State *L) {
    struct titan_browser_arguments *args = lua_touserdata(L, 1);
    assert(args->argc == 1 && args->lengths[0] == 1);
    int failures = args->argv[0][0];
    configure_flush_devices(failures, EIO);
    assert(freopen("/dev/browser-entry-stdout", "w", stdout) != NULL);
    assert(freopen("/dev/browser-entry-stderr", "w", stderr) != NULL);
    static char out_buffer[BUFSIZ], err_buffer[BUFSIZ];
    assert(setvbuf(stdout, out_buffer, _IOFBF, sizeof out_buffer) == 0);
    assert(setvbuf(stderr, err_buffer, _IOFBF, sizeof err_buffer) == 0);
    assert(fputs("out-tail", stdout) >= 0);
    assert(fputs("err-tail", stderr) >= 0);
    if (failures & 4) {
        lua_pushliteral(L, "original failure");
        return lua_error(L);
    }
    lua_pushinteger(L, 37);
    return 1;
}
