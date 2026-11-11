#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <windows.h>
#include <wchar.h>
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
#include "titan.h"

/* Exercise the unexpected-error contract independently of machine environment
** contents, at both the initial size query and the retry/read boundary. */
static DWORD fixture_environment_query(LPCWSTR name, LPWSTR value, DWORD size) {
    if (wcscmp(name, L"fixture.initial-error") == 0) {
        SetLastError(ERROR_INVALID_PARAMETER);
        return 0;
    }
    if (wcscmp(name, L"fixture.retry-error") == 0) {
        if (size == 0) return 8;
        SetLastError(ERROR_ACCESS_DENIED);
        return 0;
    }
    return GetEnvironmentVariableW(name, value, size);
}
#define GetEnvironmentVariableW fixture_environment_query
#include "titan_winloader.h"
#undef GetEnvironmentVariableW

static int environment_initial_error(lua_State *L) {
    return titan_win_push_environment(L, L"fixture.initial-error");
}
static int environment_retry_error(lua_State *L) {
    return titan_win_push_environment(L, L"fixture.retry-error");
}

static int check_provider(lua_State *L) {
    const char *file = luaL_checkstring(L, 1);
    void *library = loadlib(L, file);
    TitanModuleProvider provider = { library, NULL };
    titan_check_module_abi(L, provider, "fixture_alpha_abi", file);
    return 0;
}

static int raise_error(lua_State *L) {
    return luaL_error(L, "Windows runtime diagnostic canary");
}

static int open_native(lua_State *L) {
    typedef int (*value_fn)(void);
    void *library = loadlib(L, "fixture-native.dll");
    value_fn value = titan_cast_func(value_fn,
        loadsym(L, library, "titan_loader_native_value"));
    assert(value() == 37);
    return 0;
}

static void expect_error(lua_State *L, lua_CFunction function,
                           const char *argument, const char *message) {
    int top = lua_gettop(L);
    lua_pushcfunction(L, function);
    lua_pushstring(L, argument);
    assert(lua_pcall(L, 1, 0, 0) != LUA_OK);
    if (!strstr(lua_tostring(L, -1), message)) {
        fprintf(stderr, "expected %s, received %s\n", message, lua_tostring(L, -1));
        abort();
    }
    lua_settop(L, top);
}

/* The scratch runtime keeps this probe in bin/ beside lib/lua/5.5 and
** lib/titan/0.6, so its own executable names both without environment help. */
static void fixture_runtime_root(char *root, size_t size) {
    static const char suffix[] = "\\bin\\runtime-loader-probe.exe";
    wchar_t module[32768];
    char buffer[sizeof(module) / sizeof(module[0])];
    DWORD length = GetModuleFileNameW(NULL, module,
        (DWORD)(sizeof(module) / sizeof(module[0])));
    int bytes, separator;
    assert(length > 0 && length < sizeof(module) / sizeof(module[0]));
    bytes = WideCharToMultiByte(CP_UTF8, 0, module, (int)length, buffer,
        (int)(sizeof(buffer) - 1), NULL, NULL);
    assert(bytes > 0);
    buffer[bytes] = '\0';
    assert(strlen(buffer) > sizeof(suffix) - 1 &&
        strcmp(buffer + strlen(buffer) - (sizeof(suffix) - 1), suffix) == 0);
    for (separator = bytes - 1; separator > 0 && buffer[separator] != '\\'; separator--);
    assert(separator > 0);
    buffer[separator] = '\0';  /* drop the executable name: ...\bin */
    for (separator--; separator > 0 && buffer[separator] != '\\'; separator--);
    assert(separator > 0);
    buffer[separator] = '\0';  /* drop bin: the runtime root */
    assert(strlen(buffer) < size);
    memcpy(root, buffer, strlen(buffer) + 1);
}

static void run_lua(lua_State *L, const char *source) {
    if (luaL_dostring(L, source) != LUA_OK) {
        fprintf(stderr, "%s\n", lua_tostring(L, -1));
        abort();
    }
}

static int initialize_provider(lua_State *L) {
    typedef Udata *(*init_fn)(lua_State *);
    TitanModuleProvider selected = titan_module_provider(L,
        "fixture.alpha", "fixture-provider.dll");
    TitanModuleProvider canonical;
    titan_check_module_abi(L, selected, "fixture_alpha_abi", "fixture-provider.dll");
    titan_cast_func(init_fn,
        titan_module_symbol(L, selected, "fixture_alpha_init"))(L);
    canonical = titan_module_provider(L, "fixture.alpha", "does-not-exist.dll");
    assert(canonical.handle == NULL && canonical.symbols != NULL);
    titan_check_module_abi(L, canonical, "fixture_alpha_abi", "does-not-exist.dll");
    assert(titan_module_symbol(L, selected, "fixture_alpha_init") ==
        titan_module_symbol(L, canonical, "fixture_alpha_init"));
    assert(titan_module_provider(L, "fixture.beta", NULL).symbols != NULL);
    return 0;
}

/* The support module is an ordinary Lua native module installed under the
** package cpath, so open it the way a Lua host does instead of feeding an
** absolute image path to the Titan provider search. */
static void load_support(lua_State *L, const char *path) {
    const char *message;
    int base = lua_gettop(L);
    lua_getglobal(L, "package");
    lua_getfield(L, -1, "loadlib");
    lua_remove(L, -2);
    lua_pushstring(L, path);
    lua_pushliteral(L, "luaopen_titan");
    /* Success leaves the opener alone; failure returns fail, message, where,
    ** and a raised error leaves one error object. */
    if (lua_pcall(L, 2, LUA_MULTRET, 0) != LUA_OK
            || !lua_isfunction(L, base + 1)) {
        message = lua_gettop(L) >= base + 2
            ? lua_tostring(L, base + 2) : lua_tostring(L, -1);
        fprintf(stderr, "cannot load support module %s: %s\n", path,
            message != NULL ? message : "(non-string error)");
        abort();
    }
    lua_settop(L, base + 1);
    if (lua_pcall(L, 0, 1, 0) != LUA_OK) {
        message = lua_tostring(L, -1);
        fprintf(stderr, "support module %s failed to open: %s\n", path,
            message != NULL ? message : "(non-string error)");
        abort();
    }
}

int main(int argc, char **argv) {
    typedef const char *(*query_fn)(void);
    lua_State *L = luaL_newstate();
    HMODULE provider;
    query_fn query;
    char runtime_root[2048];
    char support_path[2048];
    int written;
    fixture_runtime_root(runtime_root, sizeof(runtime_root));
    assert(L != NULL);
    luaL_checkversion(L);
    luaL_openlibs(L);
    titan_install_searcher(L);
    expect_error(L, environment_initial_error, "", "Windows error 87");
    expect_error(L, environment_retry_error, "", "Windows error 5");

    /* Each dependency-search canary runs in a fresh process. A successful
    ** earlier mapping must not satisfy the negative test from loader state. */
    if (argc == 2 && strcmp(argv[1], "reject-native") == 0) {
        expect_error(L, open_native, "", "Windows error 126");
        lua_close(L);
        puts("Windows absent native dependency diagnostic ok");
        return 0;
    }
    if (argc == 2 && strcmp(argv[1], "reject-empty") == 0) {
        expect_error(L, open_native, "", "search path is empty");
        lua_close(L);
        puts("Windows empty versioned Titan path ok");
        return 0;
    }
    lua_pushcfunction(L, open_native);
    assert(lua_pcall(L, 0, 0, 0) == LUA_OK);
    expect_error(L, check_provider, "fixture-bad.dll", "ABI mismatch");
    expect_error(L, check_provider, "fixture-missing.dll", "missing ABI symbol");
    expect_error(L, check_provider, "fixture-null.dll", "invalid ABI marker");

    lua_pushstring(L, runtime_root);
    lua_setglobal(L, "fixture_root");
    written = snprintf(support_path, sizeof(support_path),
        "%s/lib/lua/5.5/titan.dll", runtime_root);
    assert(written > 0 && (size_t)written < sizeof(support_path));
    load_support(L, support_path);
    lua_setglobal(L, "support");
    lua_pushcfunction(L, errorhandler);
    lua_setglobal(L, "fixture_errorhandler");
    lua_pushinteger(L, LUAL_BUFFERSIZE);
    lua_setglobal(L, "fixture_buffer_size");
    /* Force the unified traceback buffer to grow while its Lua source string
    ** stays rooted. Shallow traces do not exercise the UBox stack contract. */
    run_lua(L,
        "local recurse = assert(load('local function recurse(n) if n == 0 then error(\"trace fixture\") end return 1 + recurse(n-1) end return recurse', '@' .. string.rep('long_trace_name_', 8)))()\n"
        "for i = 1, 100 do\n"
        "  local ok, err = xpcall(recurse, fixture_errorhandler, 50)\n"
        "  assert(not ok and err:find('trace fixture', 1, true))\n"
        "  local trace = support.backtrace()\n"
        "  assert(type(trace) == 'string' and #trace > fixture_buffer_size)\n"
        "  assert(trace:find('long_trace_name_', 1, true) and trace:find(':1: in ', 1, true))\n"
        "  assert(trace:find('[C]: in ', 1, true))\n"
        "  collectgarbage('collect')\n"
        "end\n");
    lua_pushcfunction(L, errorhandler);
    lua_pushcfunction(L, raise_error);
    assert(lua_pcall(L, 0, 0, -2) != LUA_OK);
    lua_pop(L, 2); /* original error and message handler */
    run_lua(L,
        "local trace = support.backtrace()\n"
        "assert(type(trace) == 'string' and trace:find('[C]: in ', 1, true))\n");
    run_lua(L,
        "provider_dir = fixture_root .. '/lib/titan/0.6/'\n"
        "local r = debug.getregistry()\n"
        "assert(r['fixture.init.calls'] == nil and r['fixture.legacy.calls'] == nil)\n"
        "assert(support._abivalue(provider_dir .. 'fixture-provider.dll', 'fixture_alpha_abi_value') == '2')\n"
        "local f, err, stage = support._loadlibglobal(provider_dir .. 'fixture-bad.dll', 'luaopen_fixture_alpha', 'fixture.alpha')\n"
        "assert(f == nil and stage == 'abi' and err:find('ABI mismatch', 1, true))\n"
        "f, err, stage = support._abivalue(provider_dir .. 'fixture-missing.dll', 'fixture_alpha_abi_value')\n"
        "assert(f == nil and stage == 'init')\n"
        "f, err, stage = support._abivalue(provider_dir .. 'fixture-null.dll', 'fixture_alpha_abi_value')\n"
        "assert(f == nil and stage == 'abi')\n"
        "f, err, stage = support._abivalue(string.char(255), 'fixture_alpha_abi_value')\n"
        "assert(f == nil and stage == 'open')\n"
        "assert(not pcall(support._abivalue, provider_dir .. 'fixture-provider.dll' .. string.char(0) .. '.wrong', 'fixture_alpha_abi_value'))\n"
        "assert(r['fixture.init.calls'] == nil and r['fixture.legacy.calls'] == nil)\n");
    lua_pushcfunction(L, initialize_provider);
    if (lua_pcall(L, 0, 0, 0) != LUA_OK) {
        fprintf(stderr, "%s\n", lua_tostring(L, -1));
        abort();
    }
    run_lua(L,
        "local r = debug.getregistry()\n"
        "local canonical = r['Titan module fixture.alpha']\n"
        "assert(type(canonical) == 'userdata' and r['fixture.init.calls'] == 2)\n"
        "for _, file in ipairs({'not-present.dll', 'fixture-bad.dll'}) do\n"
        "  local open = assert(support._loadlibglobal(provider_dir .. file, 'luaopen_fixture_alpha', 'fixture.alpha'))\n"
        "  assert(open() == canonical)\n"
        "end\n"
        "local gamma = assert(support._loadlibglobal(provider_dir .. 'fixture-provider.dll', 'luaopen_fixture_gamma', 'fixture.gamma'))()\n"
        "assert(gamma ~= canonical and gamma == r['Titan module fixture.gamma'])\n"
        "assert(r['fixture.init.calls'] == 3 and r['fixture.legacy.calls'] == nil)\n"
        "local make = assert(support._loadlib(provider_dir .. 'fixture-provider.dll', 'fixture_make_finalizer'))\n"
        "do local object = make() end\n"
        "collectgarbage('collect')\n"
        "assert(r['fixture.finalizer.calls'] == 1)\n"
        "fixture_late_finalizer = make()\n");
    provider = GetModuleHandleW(L"fixture-provider.dll");
    assert(provider != NULL);
    query = titan_cast_func(query_fn, GetProcAddress(provider, "fixture_alpha_abi_value"));
    assert(query != NULL);
    lua_close(L);
    assert(GetModuleHandleW(L"fixture-provider.dll") == provider);
    assert(strcmp(query(), TITAN_ABI_VERSION) == 0);
    L = luaL_newstate();
    assert(L != NULL);
    luaL_checkversion(L);
    luaL_openlibs(L);
    titan_install_searcher(L);
    lua_pushcfunction(L, initialize_provider);
    assert(lua_pcall(L, 0, 0, 0) == LUA_OK);
    run_lua(L, "assert(debug.getregistry()['fixture.init.calls'] == 2)");
    lua_close(L);
    assert(strcmp(query(), TITAN_ABI_VERSION) == 0);
    puts("Windows Titan runtime loader ok");
    return 0;
}
