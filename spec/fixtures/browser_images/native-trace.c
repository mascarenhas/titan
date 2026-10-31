#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
#include "titan.h"
#if !defined(FIXTURE_NULL)
#if defined(_WIN32)
#include <windows.h>
#else
#include <execinfo.h>
#endif
#endif

#if defined(_MSC_VER)
#define NOINLINE __declspec(noinline)
#else
#define NOINLINE __attribute__((noinline))
#endif

static char long_name[701];
static char name_prefix[201];
static size_t shallow_count, deep_count, longest_trace;

static size_t native_frames(const char *trace, void **frames, const char **first) {
    size_t count = 0;
    const char *line = trace;
    *first = NULL;
    while (*line) {
        const char *end = strchr(line, '\n');
        const char *address;
        void *frame;
        if (!end) end = line + strlen(line);
#if defined(_WIN32)
        address = strstr(line, "[native address ");
        if (address && address < end) address += strlen("[native address ");
#else
        address = memchr(line, '[', (size_t)(end - line));
        if (address) address++;
#endif
        if (address && address < end && sscanf(address, "%p", &frame) == 1) {
            assert(count < 512);
            frames[count++] = frame;
            if (!*first) *first = line;
        }
        line = *end ? end + 1 : end;
    }
    return count;
}

NOINLINE int fixture_trace_leaf(lua_State *L, int depth) {
    void *expected[512], *actual[512];
    const char *trace, *first_native;
    size_t length, count, expected_count = 0;
    int top = lua_gettop(L);
#if !defined(FIXTURE_NULL)
#if defined(_WIN32)
    expected_count = CaptureStackBackTrace(0, 512, expected, NULL);
#else
    expected_count = (size_t)backtrace(expected, 512);
#endif
#endif
    lua_pushliteral(L, "trace fixture error");
    assert(errorhandler(L) == 1);
    assert(lua_gettop(L) == top + 1);
    lua_getfield(L, LUA_REGISTRYINDEX, TITAN_BACKTRACE_KEY);
    trace = lua_tolstring(L, -1, &length);
    assert(trace != NULL);
    assert(strstr(trace, name_prefix) != NULL);
    assert(strstr(trace, "stack traceback:") == NULL);
    if (length > longest_trace) longest_trace = length;
    count = native_frames(trace, actual, &first_native);
#if defined(FIXTURE_NULL)
    (void)expected;
    (void)expected_count;
    assert(count == 0);
    assert(first_native == NULL);
    assert(strstr(trace, "native-trace-fixture.lua:") != NULL);
#else
    assert(expected_count >= 3);
    assert(count == (expected_count + 1 < 255 ? expected_count + 1 : 255));
    assert(first_native != NULL && strstr(trace, name_prefix) < first_native);
    /* Capture occurs in errorhandler itself, not in another helper. Only the
       leaf's two distinct call-site PCs differ; every parent's exact PC agrees. */
    for (size_t i = 2; i < count; i++) assert(actual[i] == expected[i - 1]);
#if !defined(_WIN32) && !defined(__APPLE__)
    assert(strstr(first_native, "errorhandler+") != NULL);
    assert(strstr(first_native, "fixture_trace_leaf+") != NULL);
    assert(strstr(first_native, "fixture_trace_parent+") != NULL);
#endif
#endif
    if (depth < 100) shallow_count = count; else deep_count = count;

    /* Preserve the exact existing owner once, then allow a fresh capture. */
    lua_pushboolean(L, 1);
    lua_setfield(L, LUA_REGISTRYINDEX, TITAN_TRACE_PINNED);
    lua_pushliteral(L, "rethrow fixture error");
    assert(errorhandler(L) == 1);
    lua_getfield(L, LUA_REGISTRYINDEX, TITAN_BACKTRACE_KEY);
    assert(lua_rawequal(L, -1, -3));
    lua_pop(L, 1);
    lua_getfield(L, LUA_REGISTRYINDEX, TITAN_TRACE_PINNED);
    assert(!lua_toboolean(L, -1));
    lua_pop(L, 1);
    lua_settop(L, top);
    return 0;
}

NOINLINE int fixture_trace_parent(lua_State *L, int remaining, int depth) {
    volatile int canary = remaining;
    int result = remaining ? fixture_trace_parent(L, remaining - 1, depth) : fixture_trace_leaf(L, depth);
    assert(canary == remaining);
    return result;
}

static int probe(lua_State *L) {
    int depth = (int)luaL_checkinteger(L, 1);
    lua_pushnil(L);
    lua_setfield(L, LUA_REGISTRYINDEX, TITAN_BACKTRACE_KEY);
    return fixture_trace_parent(L, depth, depth);
}

int main(void) {
    lua_State *L = luaL_newstate();
    char script[4096];
    assert(L != NULL);
    luaL_openlibs(L);
    memset(long_name, 'n', sizeof(long_name) - 1);
    memset(name_prefix, 'n', sizeof(name_prefix) - 1);
    lua_pushcfunction(L, probe);
    lua_setglobal(L, "trace_probe");
    snprintf(script, sizeof(script),
        "local function %s(n, depth) if n > 0 then return 1 + %s(n - 1, depth) "
        "else trace_probe(depth); return 0 end end; %s(40, 3); %s(40, 300)",
        long_name, long_name, long_name, long_name);
    assert(luaL_loadbuffer(L, script, strlen(script), "@native-trace-fixture.lua") == LUA_OK);
    assert(lua_pcall(L, 0, 0, 0) == LUA_OK);
    assert(longest_trace > 8192); /* Exercise the Windows Lua-trace UBox growth. */
    lua_pushliteral(L, "fresh trace");
    assert(errorhandler(L) == 1);
    lua_getfield(L, LUA_REGISTRYINDEX, TITAN_BACKTRACE_KEY);
    assert(strstr(lua_tostring(L, -1), name_prefix) == NULL);
#if defined(FIXTURE_NULL)
    printf("null shallow=%zu deep=%zu long-trace=%zu\n", shallow_count, deep_count, longest_trace);
#else
    assert(shallow_count > 3 && shallow_count < 255);
    assert(deep_count == 255);
    printf("fallback shallow=%zu deep=%zu long-trace=%zu\n", shallow_count, deep_count, longest_trace);
#endif
    lua_close(L);
    return 0;
}
