/*
** Titan module location: the executable directory, the compiler root, Titan
** path expansion, each Lua state's effective Titan path with its lazy SDK
** fallback, native preload descriptors, provider loading, and the Titan
** package searcher.
**
** libtitan.a links this file into executables and providers, and the support
** module (titan.so/titan.dll) links it beside ltitanlib.c. Every image owns a
** private copy of the code. All semantic state lives in the registry of the
** Lua state that uses it, never in C globals, so images and states never share
** a cache by accident. The file calls only public Lua API functions.
*/
/* Implementation notes: doc/implementation/driver.md#module-names-and-the-search-paths */
#if defined(__linux__)
#if !defined(_GNU_SOURCE)
#define _GNU_SOURCE
#endif
#elif !defined(_WIN32) && !defined(_XOPEN_SOURCE)
#define _XOPEN_SOURCE 700
#endif
#if defined(__APPLE__) && !defined(_DARWIN_C_SOURCE)
#define _DARWIN_C_SOURCE
#endif
#if defined(_WIN32) && !defined(_WIN32_WINNT)
#define _WIN32_WINNT 0x0602
#endif

#include <errno.h>
#include <stdlib.h>
#include <string.h>
#if !defined(_WIN32)
#include <dlfcn.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <spawn.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <crt_externs.h>
#include <mach-o/dyld.h>
#endif
#endif

#include "lua.h"
#include "lauxlib.h"
#include "titan.h"
#if defined(_WIN32)
#include "titan_winloader.h"
#endif

/* Registry marker: this state already has a Titan searcher. Each image has its
** own searcher function, so identity of the function pointer cannot tell. */
#define TITAN_SEARCHER_KEY "6f0b7c1e-3f0a-4b8e-9c55-2d3b1f6a9e47"
/* Registry record { path = <effective path>, root = <dir>|false, reason = <s> }
** for a default-derived path; absent for an explicit one. */
#define TITAN_SDK_FALLBACK_KEY "c2a9e5d4-1b7f-4e3a-8d26-5f9b0c7a4e18"
#define TITAN_ROOT_VAR "TITAN_ROOT"
#define TITANC_VAR "TITANC"
#define TITAN_PROVIDER_DIR "lib/titan/" TITAN_LIBRARY_VERSION
#define TITAN_RUNTIME_DEFAULT_PATH "!;!/../" TITAN_PROVIDER_DIR
#if defined(_WIN32)
#define TITAN_PROVIDER_SUFFIX ".dll"
#else
#define TITAN_PROVIDER_SUFFIX ".so"
#endif
/* Upper bound on the bytes accepted from `titanc --print-root`. */
#define TITAN_ROOT_QUERY_CAP 8192

static int titan_path_is_separator(char c) {
#if defined(_WIN32)
    return c == '/' || c == '\\';
#else
    return c == '/';
#endif
}

static int titan_path_is_absolute(const char *path) {
#if defined(_WIN32)
    if (titan_path_is_separator(path[0]) && titan_path_is_separator(path[1]))
        return 1;  /* UNC or extended-length */
    return ((path[0] >= 'A' && path[0] <= 'Z') ||
            (path[0] >= 'a' && path[0] <= 'z')) &&
        path[1] == ':' && titan_path_is_separator(path[2]);
#else
    return path[0] == '/';
#endif
}

/* ======================================================================== */
/* Platform primitives. Each "push" helper that can fail returns 1 with its  */
/* result pushed, or 0 with one diagnostic string pushed.                    */
/* ======================================================================== */

#if defined(_WIN32)
/* Push a Lua-owned wide copy of a UTF-8 string; raise when it is invalid. */
static WCHAR *titan_path_push_wide(lua_State *L, const char *utf8) {
    int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8, -1,
        NULL, 0);
    WCHAR *wide;
    if (count == 0 || (unsigned)count > TITAN_WIN_PATH_CAP) {
        titan_win_loader_error(L, "cannot decode Windows path", utf8,
            count == 0 ? GetLastError() : ERROR_FILENAME_EXCED_RANGE);
        lua_error(L);
    }
    wide = (WCHAR *)lua_newuserdatauv(L, (size_t)count * sizeof(WCHAR), 0);
    if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8, -1, wide,
            count)) {
        titan_win_loader_error(L, "cannot decode Windows path", utf8,
            GetLastError());
        lua_error(L);
    }
    return wide;
}
#endif

/* Push a present environment value (empty included) and return 1; return 0
** with nothing pushed when the variable is absent. */
static int titan_path_push_env(lua_State *L, const char *name) {
#if defined(_WIN32)
    WCHAR wide[64];
    size_t index, length = strlen(name);
    if (length >= sizeof(wide) / sizeof(wide[0]))
        luaL_error(L, "environment variable name '%s' is too long", name);
    for (index = 0; index <= length; index++)
        wide[index] = (WCHAR)(unsigned char)name[index];
    return titan_win_push_environment(L, wide);
#else
    const char *value = getenv(name);
    if (value == NULL) return 0;
    lua_pushstring(L, value);
    return 1;
#endif
}

/* Like titan_path_push_env, but an empty value counts as unset. */
static int titan_path_push_nonempty_env(lua_State *L, const char *name) {
    if (!titan_path_push_env(L, name)) return 0;
    if (lua_rawlen(L, -1) > 0) return 1;
    lua_pop(L, 1);
    return 0;
}

/* Push the directory containing the running executable, symlinks resolved on
** Unix (Linux /proc/self/exe, macOS _NSGetExecutablePath plus realpath) and
** as GetModuleFileNameW reports it on Windows. */
static int titan_path_push_executable_dir(lua_State *L) {
#if defined(_WIN32)
    int top = lua_gettop(L);
    DWORD capacity = 256;
    WCHAR *wide, *cursor, *last = NULL;
    luaL_checkstack(L, 3, "locating the Windows executable");
    for (;;) {
        DWORD length;
        wide = (WCHAR *)lua_newuserdatauv(L, capacity * sizeof(WCHAR), 0);
        length = GetModuleFileNameW(NULL, wide, capacity);
        if (length == 0) {
            DWORD error = GetLastError();
            lua_settop(L, top);
            titan_win_loader_error(L, "cannot locate executable", "", error);
            return 0;
        }
        if (length < capacity) break;
        lua_pop(L, 1);
        if (capacity >= TITAN_WIN_PATH_CAP) {
            lua_pushliteral(L, "Windows executable path exceeds supported length");
            return 0;
        }
        capacity *= 2;
        if (capacity > TITAN_WIN_PATH_CAP) capacity = TITAN_WIN_PATH_CAP;
    }
    for (cursor = wide; *cursor != L'\0'; cursor++)
        if (*cursor == L'\\' || *cursor == L'/') last = cursor;
    if (last == NULL) {
        lua_settop(L, top);
        lua_pushliteral(L, "cannot locate the Windows executable directory");
        return 0;
    }
    /* Keep the separator of a drive root (C:\app.exe -> C:\). */
    if (last == wide + 2 && wide[1] == L':') last++;
    *last = L'\0';
    titan_win_push_utf8(L, wide);
    lua_replace(L, top + 1);
    lua_settop(L, top + 1);
    return 1;
#else
    char resolved[PATH_MAX];
    char *slash;
#if defined(__APPLE__)
    int top = lua_gettop(L);
    uint32_t size = 0;
    char *raw;
    (void)_NSGetExecutablePath(NULL, &size);
    raw = (char *)lua_newuserdatauv(L, (size_t)size + 1, 0);
    if (_NSGetExecutablePath(raw, &size) != 0) {
        lua_settop(L, top);
        lua_pushliteral(L, "cannot locate the executable");
        return 0;
    }
    if (realpath(raw, resolved) == NULL) {
        int error = errno;
        lua_settop(L, top);
        lua_pushfstring(L, "cannot resolve the executable path: %s",
            strerror(error));
        return 0;
    }
    lua_settop(L, top);
#else
    if (realpath("/proc/self/exe", resolved) == NULL) {
        lua_pushfstring(L, "cannot resolve the executable path: %s",
            strerror(errno));
        return 0;
    }
#endif
    slash = strrchr(resolved, '/');
    if (slash == NULL) {
        lua_pushliteral(L, "cannot locate the executable directory");
        return 0;
    }
    if (slash == resolved) slash++;  /* keep the root directory */
    lua_pushlstring(L, resolved, (size_t)(slash - resolved));
    return 1;
#endif
}

/* Push the lexical parent of a directory, keeping a filesystem root. */
static void titan_path_push_parent(lua_State *L, const char *dir, size_t length) {
    size_t end = length, position;
    while (end > 1 && titan_path_is_separator(dir[end - 1])) {
#if defined(_WIN32)
        if (end == 3 && dir[1] == ':') break;
#endif
        end--;
    }
    position = end;
    while (position > 0 && !titan_path_is_separator(dir[position - 1]))
        position--;
    if (position == 0) {  /* no separator: nothing to remove */
        lua_pushlstring(L, dir, end);
        return;
    }
    position--;  /* index of the separator */
#if defined(_WIN32)
    if (position == 2 && dir[1] == ':') {
        lua_pushlstring(L, dir, 3);
        return;
    }
#endif
    lua_pushlstring(L, dir, position == 0 ? 1 : position);
}

#if !defined(_WIN32)
/* Push the lexical normal form of an absolute Unix path: empty and `.`
** components vanish and `..` removes the previous component (or stays at /).
** This is the driver's normalize_absolute_path. */
static void titan_path_push_lexical(lua_State *L, const char *path, size_t length) {
    char *out = (char *)lua_newuserdatauv(L, length + 2, 0);
    size_t used = 1, index = 0;
    out[0] = '/';
    while (index < length) {
        size_t start, size;
        while (index < length && path[index] == '/') index++;
        start = index;
        while (index < length && path[index] != '/') index++;
        size = index - start;
        if (size == 0 || (size == 1 && path[start] == '.')) continue;
        if (size == 2 && path[start] == '.' && path[start + 1] == '.') {
            while (used > 1 && out[used - 1] != '/') used--;
            if (used > 1) used--;
            continue;
        }
        if (used > 1) out[used++] = '/';
        memcpy(out + used, path + start, size);
        used += size;
    }
    lua_pushlstring(L, out, used);
    lua_remove(L, -2);
}

static int titan_path_has_parent_component(const char *path) {
    const char *cursor = path;
    while (*cursor != '\0') {
        const char *start = cursor;
        while (*cursor != '\0' && *cursor != '/') cursor++;
        if (cursor - start == 2 && start[0] == '.' && start[1] == '.') return 1;
        while (*cursor == '/') cursor++;
    }
    return 0;
}
#else
/* Push GetFullPathNameW's absolute form of a path (relative input resolves
** against the current directory). */
static int titan_path_push_full(lua_State *L, const char *path) {
    int top = lua_gettop(L);
    WCHAR *wide, *absolute;
    DWORD capacity, length, error;
    luaL_checkstack(L, 4, "resolving a Windows path");
    wide = titan_path_push_wide(L, path);
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
    titan_win_push_utf8(L, absolute);
    lua_replace(L, top + 1);
    lua_settop(L, top + 1);
    return 1;
failed:
    error = GetLastError();
    lua_settop(L, top);
    titan_win_loader_error(L, "cannot resolve Windows path", path, error);
    return 0;
}

static int titan_path_ascii_lower(int c) {
    return c >= 'A' && c <= 'Z' ? c - 'A' + 'a' : c;
}
#endif

/* Push the normalized form of a configured root (TITAN_ROOT), following the
** driver's normalize_root: a relative value is joined to the current
** directory; a path with a `..` component resolves through the filesystem
** when it exists; everything else is normalized lexically. */
static int titan_path_push_root(lua_State *L, const char *value) {
#if defined(_WIN32)
    return titan_path_push_full(L, value);
#else
    int top = lua_gettop(L);
    const char *path;
    if (value[0] != '/') {
        char cwd[PATH_MAX];
        if (getcwd(cwd, sizeof(cwd)) == NULL) {
            lua_pushfstring(L, "cannot resolve '%s': %s", value, strerror(errno));
            return 0;
        }
        lua_pushfstring(L, "%s/%s", cwd, value);
    } else {
        lua_pushstring(L, value);
    }
    path = lua_tostring(L, top + 1);
    if (titan_path_has_parent_component(path)) {
        char resolved[PATH_MAX];
        if (realpath(path, resolved) != NULL) {
            lua_pushstring(L, resolved);
            lua_replace(L, top + 1);
            return 1;
        }
        if (errno != ENOENT && errno != ENOTDIR) {
            lua_pushfstring(L, "cannot resolve '%s': %s", path, strerror(errno));
            lua_replace(L, top + 1);
            return 0;
        }
    }
    titan_path_push_lexical(L, path, lua_rawlen(L, top + 1));
    lua_replace(L, top + 1);
    return 1;
#endif
}

/* The compiler root: a non-empty TITAN_ROOT, else the parent of the executable
** directory. Never launches a process. */
static int titan_path_push_compiler_root(lua_State *L) {
    int top = lua_gettop(L);
    luaL_checkstack(L, 4, "locating the Titan compiler root");
    if (titan_path_push_nonempty_env(L, TITAN_ROOT_VAR)) {
        if (!titan_path_push_root(L, lua_tostring(L, top + 1))) {
            lua_pushfstring(L, TITAN_ROOT_VAR ": %s", lua_tostring(L, -1));
            lua_replace(L, top + 1);
            lua_settop(L, top + 1);
            return 0;
        }
    } else {
        size_t length;
        const char *dir;
        if (!titan_path_push_executable_dir(L)) return 0;
        dir = lua_tolstring(L, top + 1, &length);
        titan_path_push_parent(L, dir, length);
    }
    lua_replace(L, top + 1);
    lua_settop(L, top + 1);
    return 1;
}

/* Push `value` with each non-overlapping `;;` replaced by `;` + default + `;`
** and each `!` replaced by the executable directory. This is one pass over the
** bytes of `value`: inserted default and directory bytes are never expanded
** again. Raises when `!` occurs and the executable directory is unknown. */
static void titan_path_push_expanded(lua_State *L, const char *value,
    size_t value_length, const char *fallback, size_t fallback_length) {
    int top = lua_gettop(L);
    const char *dir = NULL;
    size_t dir_length = 0, index = 0;
    luaL_Buffer buffer;
    luaL_checkstack(L, 4, "expanding a Titan path");
    if (memchr(value, '!', value_length) != NULL) {
        if (!titan_path_push_executable_dir(L))
            luaL_error(L, "cannot expand '!' in a Titan path: %s",
                lua_tostring(L, -1));
        dir = lua_tolstring(L, top + 1, &dir_length);
    }
    luaL_buffinit(L, &buffer);
    while (index < value_length) {
        if (value[index] == ';' && index + 1 < value_length &&
                value[index + 1] == ';') {
            luaL_addchar(&buffer, ';');
            luaL_addlstring(&buffer, fallback, fallback_length);
            luaL_addchar(&buffer, ';');
            index += 2;
        } else if (value[index] == '!') {
            luaL_addlstring(&buffer, dir, dir_length);
            index++;
        } else {
            luaL_addchar(&buffer, value[index]);
            index++;
        }
    }
    luaL_pushresult(&buffer);
    if (dir != NULL) lua_remove(L, top + 1);
}

/* Iterate the non-empty `;`-separated entries of a path. */
static const char *titan_path_next_entry(const char *cursor, const char *limit,
                                         size_t *length) {
    const char *end;
    while (cursor < limit && *cursor == ';') cursor++;
    if (cursor >= limit) return NULL;
    end = memchr(cursor, ';', (size_t)(limit - cursor));
    if (end == NULL) end = limit;
    *length = (size_t)(end - cursor);
    return cursor;
}

/* Push dir joined with a relative provider name. */
static const char *titan_path_push_join(lua_State *L, const char *dir,
    size_t dir_length, const char *relative) {
    luaL_Buffer buffer;
    luaL_buffinit(L, &buffer);
    luaL_addlstring(&buffer, dir, dir_length);
    if (dir_length > 0 && !titan_path_is_separator(dir[dir_length - 1]))
        luaL_addstring(&buffer, TITAN_PATH_SEP);
    luaL_addstring(&buffer, relative);
    luaL_pushresult(&buffer);
    return lua_tostring(L, -1);
}

/* ======================================================================== */
/* The effective Titan path of one Lua state                                 */
/* ======================================================================== */

/* Push this state's effective Titan path. A string already stored under
** TITAN_PATH_KEY is used as-is. Otherwise TITAN_PATH_0_6, then TITAN_PATH,
** then the runtime default `!;!/../lib/titan/0.6` select it; only a path
** derived from the default (no variable, or a variable containing `;;`) may
** later append the SDK fallback. Nothing here probes or launches a process. */
static void titan_path_push_effective(lua_State *L) {
    int top = lua_gettop(L);
    size_t env_length = 0;
    const char *env = NULL;
    int derived;
    luaL_checkstack(L, 6, "computing the Titan path");
    lua_pushliteral(L, TITAN_PATH_KEY);
    if (lua_rawget(L, LUA_REGISTRYINDEX) == LUA_TSTRING) return;
    lua_pop(L, 1);

    if (titan_path_push_env(L, TITAN_PATH_VAR TITAN_LIBRARY_VERSION_SUFFIX) ||
        titan_path_push_env(L, TITAN_PATH_VAR))
        env = lua_tolstring(L, top + 1, &env_length);
    derived = env == NULL ||
        (env_length >= 2 && strstr(env, ";;") != NULL);
    if (derived) {
        titan_path_push_expanded(L, TITAN_RUNTIME_DEFAULT_PATH,
            sizeof(TITAN_RUNTIME_DEFAULT_PATH) - 1, "", 0);
        if (env != NULL) {
            size_t default_length;
            const char *fallback = lua_tolstring(L, -1, &default_length);
            titan_path_push_expanded(L, env, env_length, fallback,
                default_length);
        }
    } else {
        titan_path_push_expanded(L, env, env_length, "", 0);
    }
    /* The result is on top; replace a present variable value beneath it. */
    if (env != NULL) lua_replace(L, top + 1);
    lua_settop(L, top + 1);

    lua_pushliteral(L, TITAN_PATH_KEY);
    lua_pushvalue(L, top + 1);
    lua_rawset(L, LUA_REGISTRYINDEX);

    /* Bind any SDK-fallback eligibility to this exact string. A later string
    ** stored by the application is explicit and never gains the fallback. An
    ** earlier probe outcome is kept: at most one probe per state. */
    lua_pushliteral(L, TITAN_SDK_FALLBACK_KEY);
    if (lua_rawget(L, LUA_REGISTRYINDEX) != LUA_TTABLE) {
        lua_pop(L, 1);
        if (!derived) return;
        lua_createtable(L, 0, 3);
        lua_pushliteral(L, TITAN_SDK_FALLBACK_KEY);
        lua_pushvalue(L, -2);
        lua_rawset(L, LUA_REGISTRYINDEX);
    }
    if (derived) lua_pushvalue(L, top + 1);
    else lua_pushboolean(L, 0);
    lua_setfield(L, -2, "path");
    lua_settop(L, top + 1);
}

/* Push the provider directory below a root (`<root>/lib/titan/0.6`), in the
** normalized spelling used for duplicate detection. */
static int titan_path_push_provider_dir(lua_State *L, int root) {
    size_t length;
    const char *dir = lua_tolstring(L, root, &length);
    titan_path_push_join(L, dir, length, TITAN_PROVIDER_DIR);
#if defined(_WIN32)
    if (!titan_path_push_full(L, lua_tostring(L, -1))) {
        lua_remove(L, -2);
        return 0;
    }
#else
    titan_path_push_lexical(L, lua_tostring(L, -1), lua_rawlen(L, -1));
#endif
    lua_remove(L, -2);
    return 1;
}

#if defined(_WIN32)
/* Locate titanc.exe in PATH without consulting the current directory. Pushes
** the full wide path and returns it, or returns NULL with nothing pushed. */
static WCHAR *titan_path_push_program_on_path(lua_State *L) {
    static const WCHAR leaf[] = L"\\titanc.exe";
    int top = lua_gettop(L);
    DWORD capacity, length;
    WCHAR *path, *candidate, *cursor;
    SetLastError(ERROR_SUCCESS);
    capacity = GetEnvironmentVariableW(L"PATH", NULL, 0);
    if (capacity == 0) return NULL;
    path = (WCHAR *)lua_newuserdatauv(L, capacity * sizeof(WCHAR), 0);
    length = GetEnvironmentVariableW(L"PATH", path, capacity);
    if (length == 0 || length >= capacity) {
        lua_settop(L, top);
        return NULL;
    }
    candidate = (WCHAR *)lua_newuserdatauv(L,
        ((size_t)length + sizeof(leaf) / sizeof(leaf[0])) * sizeof(WCHAR), 0);
    cursor = path;
    while (*cursor != L'\0') {
        WCHAR *start = cursor, *end;
        DWORD attributes;
        size_t size;
        while (*cursor != L'\0' && *cursor != L';') cursor++;
        end = cursor;
        if (*cursor == L';') cursor++;
        if (end - start >= 2 && *start == L'"' && end[-1] == L'"') {
            start++;
            end--;
        }
        while (end > start && (end[-1] == L'\\' || end[-1] == L'/')) end--;
        size = (size_t)(end - start);
        if (size == 0) continue;
        memcpy(candidate, start, size * sizeof(WCHAR));
        memcpy(candidate + size, leaf, sizeof(leaf));
        attributes = GetFileAttributesW(candidate);
        if (attributes != INVALID_FILE_ATTRIBUTES &&
                !(attributes & FILE_ATTRIBUTE_DIRECTORY)) {
            lua_remove(L, top + 1);
            return candidate;
        }
    }
    lua_settop(L, top);
    return NULL;
}
#endif

/* Validate one `--print-root` output line and push the root it names. */
static int titan_path_push_query_output(lua_State *L, const char *program,
    const char *output, size_t length) {
    if (length > 0 && output[length - 1] == '\n') length--;
    if (length > 0 && output[length - 1] == '\r') length--;
    if (length == 0 || memchr(output, '\n', length) != NULL ||
            memchr(output, '\r', length) != NULL ||
            memchr(output, '\0', length) != NULL) {
        lua_pushfstring(L, "'%s --print-root' did not print one root line",
            program);
        return 0;
    }
    lua_pushlstring(L, output, length);
    if (!titan_path_is_absolute(lua_tostring(L, -1))) {
        lua_pushfstring(L, "'%s --print-root' printed a relative root '%s'",
            program, lua_tostring(L, -1));
        lua_remove(L, -2);
        return 0;
    }
#if !defined(_WIN32)
    titan_path_push_lexical(L, lua_tostring(L, -1), length);
    lua_remove(L, -2);
#endif
    return 1;
}

#if !defined(_WIN32)
#if defined(__APPLE__)
#define titan_path_environ() (*_NSGetEnviron())
#else
extern char **environ;
#define titan_path_environ() environ
#endif

/* Create a close-on-exec pipe whose descriptors are all above stderr, so the
** child's descriptor actions never collide with them. */
static int titan_path_pipe(int descriptors[2]) {
    int index;
#if defined(__linux__)
    if (pipe2(descriptors, O_CLOEXEC) != 0) return -1;
#else
    if (pipe(descriptors) != 0) return -1;
    for (index = 0; index < 2; index++) {
        int flags = fcntl(descriptors[index], F_GETFD);
        if (flags < 0 ||
                fcntl(descriptors[index], F_SETFD, flags | FD_CLOEXEC) != 0) {
            int error = errno;
            close(descriptors[0]);
            close(descriptors[1]);
            errno = error;
            return -1;
        }
    }
#endif
    for (index = 0; index < 2; index++) {
        if (descriptors[index] <= STDERR_FILENO) {
            int moved = fcntl(descriptors[index], F_DUPFD_CLOEXEC,
                STDERR_FILENO + 1);
            if (moved < 0) {
                int error = errno;
                close(descriptors[0]);
                close(descriptors[1]);
                errno = error;
                return -1;
            }
            close(descriptors[index]);
            descriptors[index] = moved;
        }
    }
    return 0;
}
#endif

/* Run `$TITANC --print-root` (or `titanc` from PATH) as an argv process: no
** shell, stdin and stderr on the null device, stdout read through a pipe.
** Push the root it prints, or a diagnostic. No Lua allocation happens while
** descriptors, handles, or the child are live. */
static int titan_path_query_root(lua_State *L) {
    char output[TITAN_ROOT_QUERY_CAP];
    size_t length = 0;
    int overflow = 0;
#if defined(_WIN32)
    static const WCHAR option[] = L" --print-root";
    int top = lua_gettop(L);
    const char *program;
    WCHAR *wide_program, *command;
    LPPROC_THREAD_ATTRIBUTE_LIST list;
    SIZE_T list_size = 0;
    SECURITY_ATTRIBUTES inherit = { sizeof(SECURITY_ATTRIBUTES), NULL, TRUE };
    HANDLE read_end = NULL, write_end = NULL;
    HANDLE null_input = INVALID_HANDLE_VALUE, null_error = INVALID_HANDLE_VALUE;
    HANDLE handles[3];
    STARTUPINFOEXW startup;
    PROCESS_INFORMATION process;
    DWORD error = ERROR_SUCCESS, code = 0;
    const char *operation = NULL;
    int list_ready = 0, started = 0;
    size_t program_length;
    luaL_checkstack(L, 6, "querying the Titan SDK root");
    if (titan_path_push_nonempty_env(L, TITANC_VAR)) {
        program = lua_tostring(L, top + 1);
        wide_program = titan_path_push_wide(L, program);
    } else {
        program = "titanc";
        lua_pushliteral(L, "titanc");
        wide_program = titan_path_push_program_on_path(L);
        if (wide_program == NULL) {
            lua_settop(L, top);
            lua_pushliteral(L, "'titanc' was not found on PATH");
            return 0;
        }
    }
    program_length = wcslen(wide_program);
    command = (WCHAR *)lua_newuserdatauv(L,
        (program_length + 2 + sizeof(option) / sizeof(option[0])) *
            sizeof(WCHAR), 0);
    command[0] = L'"';
    memcpy(command + 1, wide_program, program_length * sizeof(WCHAR));
    command[program_length + 1] = L'"';
    memcpy(command + program_length + 2, option, sizeof(option));
    InitializeProcThreadAttributeList(NULL, 1, 0, &list_size);
    list = (LPPROC_THREAD_ATTRIBUTE_LIST)lua_newuserdatauv(L, list_size, 0);

    /* From here until every handle is closed, only Win32 calls run. */
    if (!CreatePipe(&read_end, &write_end, &inherit, 0)) {
        operation = "cannot create a pipe for";
        goto cleanup;
    }
    if (!SetHandleInformation(read_end, HANDLE_FLAG_INHERIT, 0)) {
        operation = "cannot configure a pipe for";
        goto cleanup;
    }
    null_input = CreateFileW(L"NUL", GENERIC_READ,
        FILE_SHARE_READ | FILE_SHARE_WRITE, &inherit, OPEN_EXISTING, 0, NULL);
    null_error = CreateFileW(L"NUL", GENERIC_WRITE,
        FILE_SHARE_READ | FILE_SHARE_WRITE, &inherit, OPEN_EXISTING, 0, NULL);
    if (null_input == INVALID_HANDLE_VALUE || null_error == INVALID_HANDLE_VALUE) {
        operation = "cannot open the null device for";
        goto cleanup;
    }
    if (!InitializeProcThreadAttributeList(list, 1, 0, &list_size)) {
        operation = "cannot prepare handle inheritance for";
        goto cleanup;
    }
    list_ready = 1;
    /* Inherit exactly the three standard handles, nothing else. */
    handles[0] = null_input;
    handles[1] = write_end;
    handles[2] = null_error;
    if (!UpdateProcThreadAttribute(list, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
            handles, sizeof(handles), NULL, NULL)) {
        operation = "cannot restrict handle inheritance for";
        goto cleanup;
    }
    ZeroMemory(&startup, sizeof(startup));
    startup.StartupInfo.cb = sizeof(startup);
    startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
    startup.StartupInfo.hStdInput = null_input;
    startup.StartupInfo.hStdOutput = write_end;
    startup.StartupInfo.hStdError = null_error;
    startup.lpAttributeList = list;
    ZeroMemory(&process, sizeof(process));
    if (!CreateProcessW(wide_program, command, NULL, NULL, TRUE,
            CREATE_NO_WINDOW | EXTENDED_STARTUPINFO_PRESENT, NULL, NULL,
            &startup.StartupInfo, &process)) {
        operation = "cannot start";
        goto cleanup;
    }
    started = 1;
    CloseHandle(write_end);
    write_end = NULL;
    for (;;) {
        char sink[512];
        DWORD count = 0;
        BOOL ok;
        if (length < sizeof(output))
            ok = ReadFile(read_end, output + length,
                (DWORD)(sizeof(output) - length), &count, NULL);
        else
            ok = ReadFile(read_end, sink, sizeof(sink), &count, NULL);
        if (!ok || count == 0) break;
        if (length < sizeof(output)) length += count;
        else overflow = 1;
    }
    WaitForSingleObject(process.hProcess, INFINITE);
    if (!GetExitCodeProcess(process.hProcess, &code)) {
        operation = "cannot read the exit status of";
    }
cleanup:
    if (operation != NULL) error = GetLastError();
    if (started) {
        CloseHandle(process.hThread);
        CloseHandle(process.hProcess);
    }
    if (list_ready) DeleteProcThreadAttributeList(list);
    if (read_end != NULL) CloseHandle(read_end);
    if (write_end != NULL) CloseHandle(write_end);
    if (null_input != INVALID_HANDLE_VALUE) CloseHandle(null_input);
    if (null_error != INVALID_HANDLE_VALUE) CloseHandle(null_error);
    lua_settop(L, top + 1);  /* keep the program name string */
    program = lua_tostring(L, top + 1);
    if (operation != NULL) {
        titan_win_loader_error(L, operation, program, error);
    } else if (code != 0) {
        lua_pushfstring(L, "'%s --print-root' exited with status %d", program,
            (int)code);
    } else if (overflow) {
        lua_pushfstring(L, "'%s --print-root' printed more than %d bytes",
            program, TITAN_ROOT_QUERY_CAP);
    } else if (titan_path_push_query_output(L, program, output, length)) {
        lua_replace(L, top + 1);
        lua_settop(L, top + 1);
        return 1;
    }
    lua_replace(L, top + 1);
    lua_settop(L, top + 1);
    return 0;
#else
    const char *program = getenv(TITANC_VAR);
    int descriptors[2];
    int status = 0, rc, waited = 0, read_error = 0;
    pid_t pid;
    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attributes;
    sigset_t mask;
    short flags = POSIX_SPAWN_SETSIGMASK;
    char *argv[3];
    if (program == NULL || program[0] == '\0') program = "titanc";
    if (titan_path_pipe(descriptors) != 0) {
        lua_pushfstring(L, "cannot create a pipe for '%s --print-root': %s",
            program, strerror(errno));
        return 0;
    }
    rc = posix_spawn_file_actions_init(&actions);
    if (rc != 0) {
        close(descriptors[0]);
        close(descriptors[1]);
        lua_pushfstring(L, "cannot start '%s --print-root': %s", program,
            strerror(rc));
        return 0;
    }
    rc = posix_spawnattr_init(&attributes);
    if (rc != 0) {
        posix_spawn_file_actions_destroy(&actions);
        close(descriptors[0]);
        close(descriptors[1]);
        lua_pushfstring(L, "cannot start '%s --print-root': %s", program,
            strerror(rc));
        return 0;
    }
    if (rc == 0) rc = posix_spawn_file_actions_addopen(&actions,
        STDIN_FILENO, "/dev/null", O_RDONLY, 0);
    if (rc == 0) rc = posix_spawn_file_actions_adddup2(&actions,
        descriptors[1], STDOUT_FILENO);
    if (rc == 0) rc = posix_spawn_file_actions_addopen(&actions,
        STDERR_FILENO, "/dev/null", O_WRONLY, 0);
    /* The calling thread's blocked signals must not leak into the child. */
    sigemptyset(&mask);
    if (rc == 0) rc = posix_spawnattr_setsigmask(&attributes, &mask);
#if defined(POSIX_SPAWN_CLOEXEC_DEFAULT)
    flags |= POSIX_SPAWN_CLOEXEC_DEFAULT;
#endif
    if (rc == 0) rc = posix_spawnattr_setflags(&attributes, flags);
    argv[0] = (char *)program;
    argv[1] = (char *)"--print-root";
    argv[2] = NULL;
    if (rc == 0) rc = posix_spawnp(&pid, program, &actions, &attributes, argv,
        titan_path_environ());
    posix_spawnattr_destroy(&attributes);
    posix_spawn_file_actions_destroy(&actions);
    close(descriptors[1]);
    if (rc != 0) {
        close(descriptors[0]);
        lua_pushfstring(L, "cannot start '%s --print-root': %s", program,
            strerror(rc));
        return 0;
    }
    for (;;) {
        char sink[512];
        ssize_t count;
        if (length < sizeof(output))
            count = read(descriptors[0], output + length, sizeof(output) - length);
        else
            count = read(descriptors[0], sink, sizeof(sink));
        if (count > 0) {
            if (length < sizeof(output)) length += (size_t)count;
            else overflow = 1;
            continue;
        }
        if (count == 0) break;
        if (errno == EINTR) continue;
        read_error = errno;
        break;
    }
    close(descriptors[0]);
    for (;;) {
        if (waitpid(pid, &status, 0) == pid) {
            waited = 1;
            break;
        }
        if (errno != EINTR) break;
    }
    if (!waited) {
        lua_pushfstring(L, "cannot wait for '%s --print-root': %s", program,
            strerror(errno));
        return 0;
    }
    if (WIFSIGNALED(status)) {
        lua_pushfstring(L, "'%s --print-root' was terminated by signal %d",
            program, WTERMSIG(status));
        return 0;
    }
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        lua_pushfstring(L, "'%s --print-root' exited with status %d", program,
            WIFEXITED(status) ? WEXITSTATUS(status) : -1);
        return 0;
    }
    if (read_error != 0) {
        lua_pushfstring(L, "cannot read from '%s --print-root': %s", program,
            strerror(read_error));
        return 0;
    }
    if (overflow) {
        lua_pushfstring(L, "'%s --print-root' printed more than %d bytes",
            program, TITAN_ROOT_QUERY_CAP);
        return 0;
    }
    return titan_path_push_query_output(L, program, output, length);
#endif
}

/* Push the SDK provider directory: `<TITAN_ROOT>/lib/titan/0.6` for a
** non-empty TITAN_ROOT, else the directory below `titanc --print-root`. */
static int titan_path_push_sdk_dir(lua_State *L) {
    int top = lua_gettop(L);
    int ok;
    luaL_checkstack(L, 4, "locating the Titan SDK");
    if (titan_path_push_nonempty_env(L, TITAN_ROOT_VAR)) {  /* top + 1 */
        ok = titan_path_push_root(L, lua_tostring(L, top + 1));
        if (!ok) {
            lua_pushfstring(L, TITAN_ROOT_VAR ": %s", lua_tostring(L, -1));
            lua_replace(L, top + 2);
        }
    } else {
        lua_pushnil(L);  /* top + 1: keeps the result slot uniform */
        ok = titan_path_query_root(L);
    }
    /* top + 2 holds the root or a diagnostic. */
    if (ok) {
        ok = titan_path_push_provider_dir(L, top + 2);
        lua_replace(L, top + 2);
    }
    lua_replace(L, top + 1);
    lua_settop(L, top + 1);
    return ok;
}

/* Does the effective path (at path_index) already list the normalized
** directory at dir_index? Relative entries never match. */
static int titan_path_lists_dir(lua_State *L, int path_index, int dir_index) {
    size_t path_length, dir_length, entry_length;
    const char *path = lua_tolstring(L, path_index, &path_length);
    const char *dir = lua_tolstring(L, dir_index, &dir_length);
    const char *limit = path + path_length;
    const char *entry = path;
    while ((entry = titan_path_next_entry(entry, limit, &entry_length)) != NULL) {
        int same = 0;
        lua_pushlstring(L, entry, entry_length);
        if (titan_path_is_absolute(lua_tostring(L, -1))) {
            size_t normal_length;
            const char *normal;
#if defined(_WIN32)
            if (titan_path_push_full(L, lua_tostring(L, -1))) {
                size_t index;
                normal = lua_tolstring(L, -1, &normal_length);
                same = normal_length == dir_length;
                for (index = 0; same && index < dir_length; index++)
                    same = titan_path_ascii_lower((unsigned char)normal[index]) ==
                        titan_path_ascii_lower((unsigned char)dir[index]);
            }
#else
            titan_path_push_lexical(L, entry, entry_length);
            normal = lua_tolstring(L, -1, &normal_length);
            same = normal_length == dir_length &&
                memcmp(normal, dir, dir_length) == 0;
#endif
            lua_pop(L, 1);
        }
        lua_pop(L, 1);
        if (same) return 1;
        entry += entry_length;
    }
    return 0;
}

/* Push the lazy SDK fallback directory for the effective path at path_index
** and return 1, or push a diagnostic string (or nil) and return 0. Only a
** default-derived path is eligible. The first eligible miss in a state probes
** once; every later miss reuses the cached outcome, including "none". */
static int titan_path_push_sdk_fallback(lua_State *L, int path_index) {
    int top = lua_gettop(L);
    int record = top + 1;
    int ok;
    path_index = lua_absindex(L, path_index);
    luaL_checkstack(L, 6, "locating the Titan SDK fallback");
    lua_pushliteral(L, TITAN_SDK_FALLBACK_KEY);
    if (lua_rawget(L, LUA_REGISTRYINDEX) != LUA_TTABLE) {
        lua_pop(L, 1);
        lua_pushnil(L);
        return 0;
    }
    lua_getfield(L, record, "path");
    if (!lua_rawequal(L, -1, path_index)) {
        lua_settop(L, top);
        lua_pushnil(L);
        return 0;
    }
    lua_pop(L, 1);
    switch (lua_getfield(L, record, "root")) {
    case LUA_TSTRING:
        lua_replace(L, record);
        return 1;
    case LUA_TNIL:
        break;
    default:
        lua_getfield(L, record, "reason");
        lua_replace(L, record);
        lua_settop(L, record);
        return 0;
    }
    lua_pop(L, 1);
    /* Record the attempt first, so even a raising probe is never repeated. */
    lua_pushboolean(L, 0);
    lua_setfield(L, record, "root");
    ok = titan_path_push_sdk_dir(L);  /* record + 1 */
    if (ok && titan_path_lists_dir(L, path_index, record + 1)) {
        ok = 0;  /* already searched: not a fallback */
        lua_pushnil(L);
        lua_replace(L, record + 1);
    }
    lua_pushvalue(L, record + 1);
    lua_setfield(L, record, ok ? "root" : "reason");
    lua_replace(L, record);
    lua_settop(L, record);
    return ok;
}

/* ======================================================================== */
/* Native preloads and canonical modules                                     */
/* ======================================================================== */

/* A preload descriptor contains only code pointers. It is kept separate from
** canonical initialized module userdata and from package.loaded. Copying these
** bytes into another state grants lookup capability, not initialized state. */
typedef struct TitanModulePreload {
    lua_CFunction loader;
    TitanModuleSymbols symbols;
} TitanModulePreload;

static void titan_path_push_registry_table(lua_State *L, const char *key) {
    lua_pushstring(L, key);
    lua_rawget(L, LUA_REGISTRYINDEX);
    if (!lua_istable(L, -1)) {
        lua_pop(L, 1);
        lua_newtable(L);
        lua_pushstring(L, key);
        lua_pushvalue(L, -2);
        lua_rawset(L, LUA_REGISTRYINDEX);
    }
}

/* An expected loader is supplied by a snapshot. Runtime lookups pass NULL and
** elect the current raw C loader themselves. Both paths reject stale or
** replaced entries before returning the descriptor's symbol capability; the
** elected loader is stored through `elected` when it is not NULL. */
static TitanModuleSymbols titan_path_find_preload(lua_State *L,
    const char *name, size_t length, lua_CFunction expected,
    lua_CFunction *elected) {
    int top = lua_gettop(L);
    lua_CFunction loader;
    TitanModuleSymbols symbols = NULL;
    luaL_checkstack(L, 4, "looking up a Titan native preload");
    lua_pushliteral(L, LUA_PRELOAD_TABLE);
    lua_rawget(L, LUA_REGISTRYINDEX);
    if (!lua_istable(L, -1)) goto done;
    lua_pushlstring(L, name, length);
    lua_rawget(L, -2);
    loader = lua_tocfunction(L, -1);
    if (loader == NULL || (expected != NULL && loader != expected)) goto done;
    if (lua_getupvalue(L, -1, 1) != NULL) goto done;
    lua_settop(L, top);

    lua_pushliteral(L, TITAN_MODULE_PRELOADS_KEY);
    lua_rawget(L, LUA_REGISTRYINDEX);
    if (!lua_istable(L, -1)) goto done;
    lua_pushlstring(L, name, length);
    lua_rawget(L, -2);
    if (lua_type(L, -1) == LUA_TUSERDATA &&
        lua_rawlen(L, -1) == sizeof(TitanModulePreload)) {
        const TitanModulePreload *entry =
            (const TitanModulePreload *)lua_touserdata(L, -1);
        if (entry->loader == loader) {
            symbols = entry->symbols;
            if (elected != NULL) *elected = loader;
        }
    }

done:
    lua_settop(L, top);
    return symbols;
}

TitanModuleSymbols titan_module_preload_symbols(lua_State *L,
    const char *name, size_t length, lua_CFunction loader) {
    if (loader == NULL) return NULL;
    return titan_path_find_preload(L, name, length, loader, NULL);
}

void titan_module_preload(lua_State *L, const char *name, size_t length,
    lua_CFunction loader, TitanModuleSymbols symbols) {
    int top = lua_gettop(L);
    luaL_checkstack(L, 4, "publishing a Titan native preload");
    if (loader == NULL) luaL_error(L, "Titan native preload loader is NULL");

    /* Publish the descriptor first. If installing the loader raises, an old
    ** different loader cannot accidentally select this new capability. */
    titan_path_push_registry_table(L, TITAN_MODULE_PRELOADS_KEY);
    lua_pushlstring(L, name, length);
    if (symbols != NULL) {
        TitanModulePreload *entry =
            (TitanModulePreload *)lua_newuserdatauv(L, sizeof(*entry), 0);
        entry->loader = loader;
        entry->symbols = symbols;
    } else lua_pushnil(L);
    lua_rawset(L, -3);
    lua_pop(L, 1);

    titan_path_push_registry_table(L, LUA_PRELOAD_TABLE);
    lua_pushlstring(L, name, length);
    lua_pushcfunction(L, loader);
    lua_rawset(L, -3);
    lua_settop(L, top);
}

/* Push this state's canonical module for a logical name and return 1, or
** return 0 with nothing pushed. Raises for a non-userdata registry entry. */
static int titan_path_push_canonical_module(lua_State *L, const char *name,
                                            size_t length) {
    luaL_checkstack(L, 3, "looking up a canonical Titan module");
    lua_pushliteral(L, "Titan module ");
    lua_pushlstring(L, name, length);
    lua_concat(L, 2);
    if (lua_rawget(L, LUA_REGISTRYINDEX) == LUA_TNIL) {
        lua_pop(L, 1);
        return 0;
    }
    if (lua_type(L, -1) != LUA_TUSERDATA) {
        lua_pop(L, 1);
        luaL_error(L, "Titan canonical module '%s' has invalid module state",
            name);
    }
    return 1;
}

/* ======================================================================== */
/* Opening providers                                                         */
/* ======================================================================== */

/* Clear the libbacktrace snapshot after mapping a new image. This is the same
** registry slot titan_invalidate_backtrace_state clears; the support module
** does not link titan.c, so the operation stays local. */
static void titan_path_invalidate_backtrace(lua_State *L) {
    lua_pushliteral(L, TITAN_BT_STATE_KEY);
    lua_pushnil(L);
    lua_rawset(L, LUA_REGISTRYINDEX);
}

/* Does a pathname exist? lstat semantics: a dangling symlink or any other
** occupied name counts, so a broken provider is never skipped silently. */
static int titan_path_occupied(lua_State *L, const char *filename) {
#if defined(_WIN32)
    int top = lua_gettop(L);
    WCHAR *wide = titan_path_push_wide(L, filename);
    DWORD attributes = GetFileAttributesW(wide), error;
    lua_settop(L, top);
    if (attributes != INVALID_FILE_ATTRIBUTES) return 1;
    error = GetLastError();
    if (error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND ||
        error == ERROR_INVALID_NAME || error == ERROR_INVALID_DRIVE)
        return 0;
    titan_win_loader_error(L, "cannot inspect Titan provider candidate",
        filename, error);
    return lua_error(L);
#else
    struct stat attributes;
    if (lstat(filename, &attributes) == 0) return 1;
    if (errno == ENOENT || errno == ENOTDIR) return 0;
    return luaL_error(L, "cannot inspect Titan provider candidate '%s': %s",
        filename, strerror(errno));
#endif
}

static void titan_path_push_libs(lua_State *L) {
    lua_pushliteral(L, TITAN_LIBS_KEY);
    if (lua_rawget(L, LUA_REGISTRYINDEX) != LUA_TTABLE) {
        lua_pop(L, 1);
        /* Keep Titan DSOs mapped for the process lifetime. A flat load-order
        ** finalizer cannot safely unload a manually wired dependency graph:
        ** the required order depends on which module was initialized first,
        ** and Lua finalizers can still hold native entry pointers. */
        lua_newtable(L);
        lua_pushliteral(L, TITAN_LIBS_KEY);
        lua_pushvalue(L, -2);
        lua_rawset(L, LUA_REGISTRYINDEX);
    }
}

#if !defined(_WIN32)
/* Push the canonical spelling of an occupied candidate: the per-state cache
** key and the exact image to open. Raises when it does not resolve. */
static const char *titan_path_push_canonical_path(lua_State *L,
                                                  const char *filename) {
    char resolved[PATH_MAX];
    if (realpath(filename, resolved) == NULL)
        luaL_error(L, "cannot load Titan provider '%s': %s", filename,
            strerror(errno));
    return lua_pushstring(L, resolved);
}

/* This state's global handle for a canonical path, or NULL. */
static void *titan_path_cached(lua_State *L, int canonical) {
    void *lib;
    titan_path_push_libs(L);
    lua_pushvalue(L, canonical);
    lua_rawget(L, -2);
    lib = lua_touserdata(L, -1);
    lua_pop(L, 2);
    return lib;
}

/* Open a canonical path lazily and globally through the per-state cache. A
** module's initializer loads its dynamic imports only after this dlopen
** returns, so ordinary unresolved calls must bind lazily. Titan's generated
** names share one process namespace; publishing every imported image lets
** those later imports satisfy the calls without module-specific rules. */
static void *titan_path_open_global(lua_State *L, int canonical) {
    void *lib = titan_path_cached(L, canonical);
    if (lib != NULL) return lib;
    lib = dlopen(lua_tostring(L, canonical), RTLD_LAZY | RTLD_GLOBAL);
    if (lib == NULL)
        luaL_error(L, "cannot load Titan provider '%s': %s",
            lua_tostring(L, canonical), dlerror());
    titan_path_push_libs(L);
    lua_pushvalue(L, canonical);
    lua_pushlightuserdata(L, lib);
    lua_rawset(L, -3);
    lua_pop(L, 1);
    titan_path_invalidate_backtrace(L);
    return lib;
}
#endif

/* Open an occupied provider candidate for this state; raises on failure. */
static void *titan_path_open_provider(lua_State *L, const char *filename) {
    int top = lua_gettop(L);
    void *lib;
#if defined(_WIN32)
    lib = titan_win_load_library(L, filename, TITAN_LIBS_KEY);
    if (lib == NULL) lua_error(L);
#else
    titan_path_push_canonical_path(L, filename);
    lib = titan_path_open_global(L, top + 1);
#endif
    lua_settop(L, top);
    return lib;
}

static void *titan_path_symbol(void *lib, const char *symbol) {
#if defined(_WIN32)
    return titan_cast_func(void *, GetProcAddress((HMODULE)lib, symbol));
#else
    return dlsym(lib, symbol);
#endif
}

/* Implementation notes: doc/implementation/binary-compatibility.md#generated-exports-and-runtime-verification */
void titan_check_abi_entry(lua_State *L, void *raw, const char *sym,
                           const char *file, const char *error) {
#if defined(_WIN32)
    typedef const char *(*titan_abi_value_fn)(void);
    const char *actual;
    if (raw == NULL)
        luaL_error(L, "Titan compiled module '%s' is missing ABI symbol '%s' "
            "(expected ABI " TITAN_ABI_VERSION "): %s", file, sym,
            error ? error : "symbol not found");
    actual = titan_cast_func(titan_abi_value_fn, raw)();
    if (actual == NULL)
        luaL_error(L, "Titan compiled module '%s' has an invalid ABI marker '%s' "
            "(expected ABI " TITAN_ABI_VERSION ")", file, sym);
    if (strcmp(actual, TITAN_ABI_VERSION) != 0)
        luaL_error(L, "Titan compiled module '%s' ABI mismatch: expected "
            TITAN_ABI_VERSION " but found %s", file, actual);
#else
    typedef int (*titan_abi_fn)(lua_State *);
    titan_abi_fn fn;
    int top = lua_gettop(L);
    int nresults;
    const char *actual;
    if (raw == NULL) {
        luaL_error(L,
            "Titan compiled module '%s' is missing ABI symbol '%s' "
            "(expected ABI " TITAN_ABI_VERSION "): %s",
            file, sym, error ? error : "symbol not found");
    }
    fn = titan_cast_func(titan_abi_fn, raw);
    nresults = fn(L);
    if (nresults != 1 || lua_gettop(L) != top + 1
        || lua_type(L, -1) != LUA_TSTRING) {
        lua_settop(L, top);
        luaL_error(L,
            "Titan compiled module '%s' has an invalid ABI marker '%s' "
            "(expected ABI " TITAN_ABI_VERSION ")",
            file, sym);
    }
    actual = lua_tostring(L, -1);
    if (strcmp(actual, TITAN_ABI_VERSION) != 0) {
        luaL_error(L,
            "Titan compiled module '%s' ABI mismatch: expected "
            TITAN_ABI_VERSION
            " but found %s",
            file, actual);
    }
    lua_settop(L, top);
#endif
}

void *loadlib(lua_State *L, const char *file) {
    int top = lua_gettop(L);
    size_t path_length, entry_length;
    const char *path, *limit, *entry, *filename, *reason;
    int entries = 0;
    void *lib;
    luaL_checkstack(L, 8, "searching for a Titan provider");
    titan_path_push_effective(L);  /* top + 1 */
    path = lua_tolstring(L, top + 1, &path_length);
    limit = path + path_length;
    entry = path;
    while ((entry = titan_path_next_entry(entry, limit, &entry_length)) != NULL) {
        entries++;
        filename = titan_path_push_join(L, entry, entry_length, file);
        if (titan_path_occupied(L, filename)) {
            lib = titan_path_open_provider(L, filename);
            lua_settop(L, top);
            return lib;
        }
        lua_pop(L, 1);
        entry += entry_length;
    }
    /* Every earlier root missed: only now may the SDK fallback be computed. */
    if (titan_path_push_sdk_fallback(L, top + 1)) {  /* top + 2 */
        size_t dir_length;
        const char *dir = lua_tolstring(L, top + 2, &dir_length);
        entries++;
        filename = titan_path_push_join(L, dir, dir_length, file);
        if (titan_path_occupied(L, filename)) {
            lib = titan_path_open_provider(L, filename);
            lua_settop(L, top);
            return lib;
        }
        lua_pop(L, 1);
        lua_pushnil(L);
        lua_replace(L, top + 2);
    }
    if (entries == 0)
        luaL_error(L, "cannot load module '%s': search path is empty", file);
    reason = lua_tostring(L, top + 2);
    luaL_error(L, "cannot load module '%s': not found in Titan path '%s'%s%s",
        file, path, reason != NULL ? "; no Titan SDK fallback: " : "",
        reason != NULL ? reason : "");
    return NULL;
}

/* Implementation notes: doc/implementation/codegen-overview.md#static-vs-dynamic-dependency-wiring */
TitanModuleProvider titan_module_provider(lua_State *L, const char *module,
                                           const char *file) {
    TitanModuleProvider provider = { NULL, NULL };
    if (titan_path_push_canonical_module(L, module, strlen(module))) {
        const TitanModuleData *data;
        if (lua_rawlen(L, -1) < sizeof(TitanModuleData)) {
            lua_pop(L, 1);
            luaL_error(L, "Titan canonical module '%s' is missing its native "
                "export descriptor", module);
        }
        data = (const TitanModuleData *)lua_touserdata(L, -1);
        provider.symbols = data->symbols;
        lua_pop(L, 1);
        if (provider.symbols == NULL)
            luaL_error(L, "Titan canonical module '%s' has an invalid native "
                "export descriptor", module);
        return provider;
    }
    if (file == NULL)
        luaL_error(L, "Titan canonical module '%s' is unavailable", module);
    provider.symbols = titan_path_find_preload(L, module, strlen(module),
        NULL, NULL);
    if (provider.symbols != NULL) return provider;
    provider.handle = loadlib(L, file);
    return provider;
}

/* ======================================================================== */
/* The Titan package searcher                                                */
/* ======================================================================== */

/* Count the components of a logical Titan module name, or return 0 for a
** name this searcher never resolves: an invalid name, a dotted name ending in
** the reserved `.titan` source marker, or the support module `titan`. */
static int titan_path_module_components(const char *name, size_t length) {
    size_t index = 0, start;
    int count = 0;
    if (length == 0) return 0;
    for (;;) {
        start = index;
        if (index >= length) return 0;  /* empty component */
        if (!((name[index] >= 'A' && name[index] <= 'Z') ||
              (name[index] >= 'a' && name[index] <= 'z') || name[index] == '_'))
            return 0;
        for (index++; index < length && name[index] != '.'; index++) {
            char c = name[index];
            if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
                  (c >= '0' && c <= '9') || c == '_' || c == '-'))
                return 0;
        }
        count++;
        if (index == length) break;
        index++;  /* skip the dot */
    }
    if (index - start == 5 && memcmp(name + start, "titan", 5) == 0)
        return 0;
    return count;
}

/* The loader returned for a canonical hit hands back the existing module. */
static int titan_path_canonical_loader(lua_State *L) {
    lua_pushvalue(L, lua_upvalueindex(1));
    return 1;
}

/* Append one "no file" line to the miss message at index msg. */
static void titan_path_add_miss(lua_State *L, int message, int filename) {
    if (lua_rawlen(L, message) > 0) lua_pushliteral(L, "\n\tno file '");
    else lua_pushliteral(L, "no file '");
    lua_pushvalue(L, filename);
    lua_pushliteral(L, "'");
    lua_concat(L, 3);
    lua_pushvalue(L, message);
    lua_insert(L, -2);
    lua_concat(L, 2);
    lua_replace(L, message);
}

/* Inspect one occupied candidate. Returns 1 with the opener and the provider
** path pushed when it claims the module, 0 for a clean ancestor nonclaim, and
** raises for every terminal state: an unopenable image, a partial claim, an
** exact candidate with no claim, an ABI mismatch, or a missing opener. The ABI
** marker is checked before any Lua opener is called (on Windows through the
** plain-C `_abi_value` query). */
static int titan_path_try_candidate(lua_State *L, const char *filename,
    const char *module, const char *prefix, int exact) {
    int top = lua_gettop(L);
    const char *abi_name, *types_name, *opener_name, *provider;
    void *lib, *abi, *types;
    lua_CFunction opener;
    luaL_checkstack(L, 8, "inspecting a Titan provider");
    abi_name = lua_pushfstring(L, "%s_abi", prefix);      /* top + 1 */
    types_name = lua_pushfstring(L, "%s_types", prefix);  /* top + 2 */
#if defined(_WIN32)
    lib = titan_win_load_library(L, filename, TITAN_LIBS_KEY);
    if (lib == NULL) lua_error(L);
    provider = lua_pushstring(L, filename);               /* top + 3 */
#else
    provider = titan_path_push_canonical_path(L, filename);  /* top + 3 */
    lib = titan_path_cached(L, top + 3);
    if (lib == NULL) {
        /* Inspect claims without publishing the image's symbols globally.
        ** The handle is never closed: Titan images stay mapped. */
        lib = dlopen(provider, RTLD_LAZY | RTLD_LOCAL);
        if (lib == NULL)
            luaL_error(L, "cannot load Titan provider '%s': %s", provider,
                dlerror());
    }
#endif
    abi = titan_path_symbol(lib, abi_name);
    types = titan_path_symbol(lib, types_name);
    if (abi == NULL && types == NULL) {
        if (exact)
            luaL_error(L, "Titan provider '%s' does not define module '%s' "
                "(no ABI marker '%s')", provider, module, abi_name);
        lua_settop(L, top);
        return 0;
    }
    if (abi == NULL || types == NULL)
        luaL_error(L, "Titan provider '%s' claims module '%s' but is missing "
            "metadata symbol '%s'", provider, module,
            abi == NULL ? abi_name : types_name);
#if defined(_WIN32)
    {
        const char *query = lua_pushfstring(L, "%s_value", abi_name);
        void *raw = titan_path_symbol(lib, query);
        titan_check_abi_entry(L, raw, query, provider,
            raw == NULL ? "export not found in Windows provider" : NULL);
        lua_pop(L, 1);
    }
#else
    titan_check_abi_entry(L, abi, abi_name, provider, NULL);
    lib = titan_path_open_global(L, top + 3);  /* promote before opening */
#endif
    opener_name = lua_pushfstring(L, "luaopen_%s", prefix);
    opener = titan_cast_func(lua_CFunction, titan_path_symbol(lib, opener_name));
    if (opener == NULL)
        luaL_error(L, "Titan provider '%s' claims module '%s' but is missing "
            "entry '%s'", provider, module, opener_name);
    lua_pushcfunction(L, opener);
    lua_pushvalue(L, top + 3);
    lua_replace(L, top + 2);
    lua_replace(L, top + 1);
    lua_settop(L, top + 2);
    return 1;
}

/* Search one directory's candidates not yet occupied in an earlier root. */
static int titan_path_search_dir(lua_State *L, const char *dir,
    size_t dir_length, int candidates, int occupied, int message,
    const char *module, const char *prefix, int count) {
    int top = lua_gettop(L);
    int index;
    for (index = 1; index <= count; index++) {
        const char *filename;
        lua_rawgeti(L, candidates, index);  /* top + 1: relative name */
        lua_pushvalue(L, top + 1);
        if (lua_rawget(L, occupied) != LUA_TNIL) {
            lua_settop(L, top);
            continue;  /* shadowed by an earlier root */
        }
        lua_pop(L, 1);
        filename = titan_path_push_join(L, dir, dir_length,
            lua_tostring(L, top + 1));  /* top + 2 */
        if (!titan_path_occupied(L, filename)) {
            titan_path_add_miss(L, message, top + 2);
            lua_settop(L, top);
            continue;
        }
        lua_pushvalue(L, top + 1);
        lua_pushboolean(L, 1);
        lua_rawset(L, occupied);
        if (titan_path_try_candidate(L, filename, module, prefix,
                index == count)) {
            lua_replace(L, top + 2);
            lua_replace(L, top + 1);
            lua_settop(L, top + 2);
            return 1;
        }
        lua_settop(L, top);
    }
    return 0;
}

/* package.searchers entry. Order: this state's canonical module, a matching
** native preload, then root-major and shallow-to-exact candidates (`a.so`,
** `a/b.so`, `a/b/c.so`) in the effective Titan path, then the lazy SDK
** fallback. Returns the opener and the provider path, or a miss message. */
static int titan_path_searcher(lua_State *L) {
    size_t length, path_length, entry_length, index;
    const char *name = luaL_checklstring(L, 1, &length);
    const char *path, *limit, *entry;
    lua_CFunction preload = NULL;
    int count, candidates, occupied, message, path_index;
    luaL_Buffer buffer;
    lua_settop(L, 1);
    if (titan_path_push_canonical_module(L, name, length)) {
        lua_pushcclosure(L, titan_path_canonical_loader, 1);
        return 1;
    }
    if (titan_path_find_preload(L, name, length, NULL, &preload) != NULL) {
        lua_pushcfunction(L, preload);
        lua_pushliteral(L, ":preload:");
        return 2;
    }
    count = titan_path_module_components(name, length);
    if (count == 0) return 0;
    luaL_checkstack(L, 12, "searching for a Titan module");

    /* Mangled symbol prefix: dots and dashes become underscores. */
    luaL_buffinit(L, &buffer);
    for (index = 0; index < length; index++)
        luaL_addchar(&buffer,
            name[index] == '.' || name[index] == '-' ? '_' : name[index]);
    luaL_pushresult(&buffer);  /* 2 */

    lua_createtable(L, count, 0);  /* 3: relative candidates */
    candidates = lua_gettop(L);
    for (index = 0; index <= length; index++) {
        if (index == length || name[index] == '.') {
            size_t offset;
            luaL_buffinit(L, &buffer);
            for (offset = 0; offset < index; offset++)
                luaL_addchar(&buffer,
                    name[offset] == '.' ? TITAN_PATH_SEP[0] : name[offset]);
            luaL_addstring(&buffer, TITAN_PROVIDER_SUFFIX);
            luaL_pushresult(&buffer);
            lua_rawseti(L, candidates, (lua_Integer)lua_rawlen(L, candidates) + 1);
        }
    }
    lua_newtable(L);  /* 4: occupied relative names */
    occupied = lua_gettop(L);
    lua_pushliteral(L, "");  /* 5: miss message */
    message = lua_gettop(L);
    titan_path_push_effective(L);  /* 6 */
    path_index = lua_gettop(L);

    path = lua_tolstring(L, path_index, &path_length);
    limit = path + path_length;
    entry = path;
    while ((entry = titan_path_next_entry(entry, limit, &entry_length)) != NULL) {
        if (titan_path_search_dir(L, entry, entry_length, candidates, occupied,
                message, name, lua_tostring(L, 2), count))
            return 2;
        entry += entry_length;
    }
    /* Every earlier root missed: only now may the SDK fallback be computed. */
    if (titan_path_push_sdk_fallback(L, path_index)) {
        size_t dir_length;
        const char *dir = lua_tolstring(L, -1, &dir_length);
        if (titan_path_search_dir(L, dir, dir_length, candidates, occupied,
                message, name, lua_tostring(L, 2), count))
            return 2;
    } else if (lua_type(L, -1) == LUA_TSTRING) {
        lua_pushliteral(L, "\n\tno Titan SDK fallback: ");
        lua_insert(L, -2);
        lua_concat(L, 2);
        if (lua_rawlen(L, message) == 0) {
            lua_pushstring(L, lua_tostring(L, -1) + 2);  /* drop "\n\t" */
            lua_replace(L, -2);
        }
        lua_pushvalue(L, message);
        lua_insert(L, -2);
        lua_concat(L, 2);
        lua_replace(L, message);
    }
    if (lua_rawlen(L, message) == 0) {
        if (path_length == 0) lua_pushliteral(L, "Titan path is empty");
        else lua_pushfstring(L, "no Titan provider claims module '%s'", name);
        return 1;
    }
    lua_pushvalue(L, message);
    return 1;
}

void titan_install_searcher(lua_State *L) {
    int top = lua_gettop(L);
    luaL_checkstack(L, 4, "installing the Titan searcher");
    lua_pushliteral(L, TITAN_SEARCHER_KEY);
    if (lua_rawget(L, LUA_REGISTRYINDEX) != LUA_TNIL) {
        lua_settop(L, top);
        return;
    }
    lua_pop(L, 1);
    if (lua_getfield(L, LUA_REGISTRYINDEX, LUA_LOADED_TABLE) != LUA_TTABLE ||
        lua_getfield(L, -1, "package") != LUA_TTABLE ||
        lua_getfield(L, -1, "searchers") != LUA_TTABLE) {
        lua_settop(L, top);
        luaL_error(L, "the Titan searcher requires the Lua package library");
    }
    lua_pushcfunction(L, titan_path_searcher);
    lua_rawseti(L, -2, (lua_Integer)lua_rawlen(L, -2) + 1);
    lua_pushliteral(L, TITAN_SEARCHER_KEY);
    lua_pushboolean(L, 1);
    lua_rawset(L, LUA_REGISTRYINDEX);
    lua_settop(L, top);
}

/* ======================================================================== */
/* Support-module entry points (registered by ltitanlib.c)                   */
/* ======================================================================== */

/* titan._executable_dir() -> string | nil, message */
int titan_path_lua_executable_dir(lua_State *L) {
    if (titan_path_push_executable_dir(L)) return 1;
    lua_pushnil(L);
    lua_insert(L, -2);
    return 2;
}

/* titan._compiler_root() -> string | nil, message */
int titan_path_lua_compiler_root(lua_State *L) {
    if (titan_path_push_compiler_root(L)) return 1;
    lua_pushnil(L);
    lua_insert(L, -2);
    return 2;
}

/* titan._expand_titan_path(value, default) -> string; nil value -> default */
int titan_path_lua_expand(lua_State *L) {
    size_t value_length, default_length;
    const char *fallback = luaL_checklstring(L, 2, &default_length);
    const char *value;
    if (lua_isnoneornil(L, 1)) {
        lua_settop(L, 2);
        return 1;
    }
    value = luaL_checklstring(L, 1, &value_length);
    titan_path_push_expanded(L, value, value_length, fallback, default_length);
    return 1;
}
