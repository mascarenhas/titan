#ifndef TITAN_WINLOADER_H
#define TITAN_WINLOADER_H

/* Private to the Windows runtime/support objects. All temporary storage is
** Lua-owned: an allocation error cannot strand a native path allocation.
** Successful loads intentionally retain their OS reference for process life. */
#include <windows.h>
#include <limits.h>
#include <wchar.h>
#include <string.h>

#define TITAN_WIN_PATH_CAP 32768u
#define TITAN_WIN_WIDEN_LITERAL_(text) L##text
#define TITAN_WIN_WIDEN_LITERAL(text) TITAN_WIN_WIDEN_LITERAL_(text)

static void titan_win_loader_error(lua_State *L, const char *operation,
                                    const char *filename, DWORD error) {
    WCHAR wide[256];
    char message[1024];
    DWORD count = FormatMessageW(FORMAT_MESSAGE_FROM_SYSTEM |
        FORMAT_MESSAGE_IGNORE_INSERTS, NULL, error, 0, wide, 256, NULL);
    int bytes = count ? WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
        wide, (int)count, message, sizeof(message) - 1, NULL, NULL) : 0;
    while (bytes > 0 && (message[bytes - 1] == '\r' ||
                         message[bytes - 1] == '\n')) bytes--;
    message[bytes] = '\0';
    lua_pushfstring(L, "%s '%s': Windows error %I%s%s", operation, filename,
        (lua_Integer)error, bytes ? ": " : "", message);
}

static const char *titan_win_loader_string(lua_State *L, int index) {
    size_t length;
    const char *value = luaL_checklstring(L, index, &length);
    luaL_argcheck(L, length < INT_MAX && memchr(value, '\0', length) == NULL,
        index, "embedded NUL or oversized Windows path/name");
    return value;
}

/* Push one UTF-8 string, or raise an error. The wide input must remain rooted
** by its caller through both allocations. */
static void titan_win_push_utf8(lua_State *L, const WCHAR *wide) {
    int top = lua_gettop(L);
    int bytes = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, wide, -1,
        NULL, 0, NULL, NULL);
    char *utf8;
    if (bytes == 0) {
        titan_win_loader_error(L, "cannot encode Windows path", "", GetLastError());
        lua_error(L);
    }
    utf8 = (char *)lua_newuserdatauv(L, (size_t)bytes, 0);
    if (!WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, wide, -1,
            utf8, bytes, NULL, NULL)) {
        titan_win_loader_error(L, "cannot encode Windows path", "", GetLastError());
        lua_error(L);
    }
    lua_pushlstring(L, utf8, (size_t)bytes - 1);
    lua_replace(L, top + 1);
    lua_settop(L, top + 1);
}

/* Success restores the entry stack. Failure leaves exactly one diagnostic.
** The per-state cache is keyed by the absolute UTF-8 spelling actually opened;
** logical module identity still belongs to TitanModuleData, not this cache. */
/* Implementation notes: doc/implementation/windows-build.md#windows-loader-boundary */
static HMODULE titan_win_load_library(lua_State *L, const char *filename,
                                       const char *registry_key) {
    int top = lua_gettop(L);
    int count;
    WCHAR *wide;
    WCHAR *absolute;
    DWORD capacity, length, error;
    HMODULE library;
    luaL_checkstack(L, 8, "loading a Windows Titan provider");
    if (strlen(filename) >= INT_MAX) {
        lua_pushliteral(L, "oversized Windows library path");
        return NULL;
    }
    count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, filename, -1,
        NULL, 0);
    if (count == 0) goto failed;
    if ((unsigned)count > TITAN_WIN_PATH_CAP) {
        SetLastError(ERROR_FILENAME_EXCED_RANGE);
        goto failed;
    }
    wide = (WCHAR *)lua_newuserdatauv(L, (size_t)count * sizeof(WCHAR), 0);
    if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, filename, -1,
            wide, count)) goto failed;
    capacity = GetFullPathNameW(wide, 0, NULL, NULL);
    if (capacity == 0) goto failed;
    for (;;) {
        if (capacity > TITAN_WIN_PATH_CAP) {
            SetLastError(ERROR_FILENAME_EXCED_RANGE);
            goto failed;
        }
        absolute = (WCHAR *)lua_newuserdatauv(L, capacity * sizeof(WCHAR), 0);
        length = GetFullPathNameW(wide, capacity, absolute, NULL);
        if (length == 0) goto failed;
        if (length < capacity) break;
        lua_pop(L, 1);
        capacity = length;
    }
    titan_win_push_utf8(L, absolute);                 /* top + 3: cache key */
    lua_getfield(L, LUA_REGISTRYINDEX, registry_key);  /* top + 4: cache */
    if (lua_isnil(L, -1)) {
        lua_pop(L, 1);
        lua_newtable(L);
        lua_pushvalue(L, -1);
        lua_setfield(L, LUA_REGISTRYINDEX, registry_key);
    }
    lua_pushvalue(L, top + 3);
    lua_rawget(L, top + 4);
    if (!lua_isnil(L, -1)) {
        library = (HMODULE)lua_touserdata(L, -1);
        lua_settop(L, top);
        return library;
    }
    lua_pop(L, 1);
    library = LoadLibraryExW(absolute, NULL, 0);
    if (library == NULL) goto failed;
    lua_pushvalue(L, top + 3);
    lua_pushlightuserdata(L, library);
    lua_rawset(L, top + 4);
    /* Clear the shared libbacktrace snapshot only when a new image is mapped.
    ** Keep this registry operation local: the support-only bootstrap does not
    ** link the full Titan runtime. Generated openers also invalidate it. */
    lua_pushliteral(L, TITAN_BT_STATE_KEY);
    lua_pushnil(L);
    lua_rawset(L, LUA_REGISTRYINDEX);
    lua_settop(L, top);
    return library;
failed:
    error = GetLastError();
    lua_settop(L, top);
    titan_win_loader_error(L, "cannot load library", filename, error);
    return NULL;
}

/* Push the UTF-8 value, preserving the distinction between absent and empty. */
static int titan_win_push_environment(lua_State *L, const WCHAR *name) {
    int top = lua_gettop(L);
    DWORD capacity, length;
    WCHAR *wide;
    luaL_checkstack(L, 4, "reading the Windows Titan environment");
    SetLastError(ERROR_SUCCESS);
    capacity = GetEnvironmentVariableW(name, NULL, 0);
    if (capacity == 0) {
        DWORD error = GetLastError();
        if (error == ERROR_ENVVAR_NOT_FOUND) return 0;
        if (error != ERROR_SUCCESS) {
            titan_win_loader_error(L, "cannot read Windows environment",
                "Titan environment variable", error);
            lua_error(L);
        }
        lua_pushliteral(L, "");
        return 1;
    }
    for (;;) {
        wide = (WCHAR *)lua_newuserdatauv(L, capacity * sizeof(WCHAR), 0);
        SetLastError(ERROR_SUCCESS);
        length = GetEnvironmentVariableW(name, wide, capacity);
        if (length == 0) {
            DWORD error = GetLastError();
            lua_settop(L, top);
            if (error == ERROR_ENVVAR_NOT_FOUND) return 0;
            if (error != ERROR_SUCCESS) {
                titan_win_loader_error(L, "cannot read Windows environment",
                    "Titan environment variable", error);
                lua_error(L);
            }
            lua_pushliteral(L, "");
            return 1;
        }
        if (length < capacity) break;
        lua_pop(L, 1);
        capacity = length;
    }
    titan_win_push_utf8(L, wide);
    lua_replace(L, top + 1);
    lua_settop(L, top + 1);
    return 1;
}

#endif
