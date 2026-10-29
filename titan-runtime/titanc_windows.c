/* Native Windows titanc.exe: the upstream lua.c front end, compiled separately
 * with -Dmain=titan_lua_main, linked against the import library of the single
 * controlled lua55.dll. No Lua engine is compiled into this executable, so the
 * lua.exe installed beside it runs the same engine for compiler subprocesses.
 *
 * The UTF-16 command line becomes UTF-8 and lua.c receives
 *     <this executable> -E <root>\share\lua\5.5\titan-compiler\titanc.lua ARGS
 * where <root> is the parent of this executable's directory. The unchanged
 * titanc script, which the rock installs as an ordinary Lua file there, is
 * therefore arg[0], the real frontend that object certificates hash. Every
 * user argument follows the script, so none is read as a Lua option. -E keeps
 * LUA_INIT, LUA_INIT_5_5, and the LUA_PATH/LUA_CPATH variables out, so the
 * compiler modules resolve through Lua's built-in Windows defaults: their
 * executable-relative entries (!\lua\, !\, and !\..\share\lua\5.5\ for Lua
 * files; !\ and !\..\lib\lua\5.5\ for C modules) precede the current-directory
 * entries (.\?.lua, .\?\init.lua, .\?.dll). An installed module is therefore
 * always taken from the SDK that contains the executable, and only a module
 * missing from the SDK can be found in the current directory, as with the Unix
 * compiler's ./?.lua.
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <wchar.h>

#include "lua.h"

int titan_lua_main(int argc, char **argv);

static char *utf8(const wchar_t *wide) {
    int size = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, wide, -1,
                                  NULL, 0, NULL, NULL);
    char *text = size > 0 ? malloc((size_t)size) : NULL;
    if (text && !WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, wide, -1,
                                   text, size, NULL, NULL)) {
        free(text);
        text = NULL;
    }
    return text;
}

int wmain(int argc, wchar_t **wide_argv) {
    static char ignore_environment[] = "-E";
    static const wchar_t script_path[] =
        L"\\share\\lua\\" LUA_VDIR L"\\titan-compiler\\titanc.lua";
    const size_t script_length = sizeof(script_path) / sizeof(script_path[0]);
    const char *failure = "cannot read this executable's path";
    wchar_t *module = NULL, *script = NULL, *leaf, *root_end;
    char **argv = NULL;
    int count = 0, index, status = EXIT_FAILURE;
    DWORD capacity = MAX_PATH, length;
    size_t root_length;
    for (;;) {
        module = malloc((size_t)capacity * sizeof(*module));
        if (!module) goto failed;
        length = GetModuleFileNameW(NULL, module, capacity);
        if (!length) goto failed;
        if (length < capacity) break;
        free(module);
        module = NULL;
        if (capacity >= 32768) goto failed;
        capacity *= 2;
    }
    /* <root>\bin\titanc.exe: drop the file name, then its directory. */
    failure = "cannot locate the installation root above this executable";
    leaf = wcsrchr(module, L'\\');
    if (!leaf) goto failed;
    *leaf = L'\0';
    root_end = wcsrchr(module, L'\\');
    *leaf = L'\\';
    if (!root_end || root_end == module) goto failed;
    root_length = (size_t)(root_end - module);
    failure = "cannot prepare the native UTF-8 command line";
    if (argc < 1 || argc > INT_MAX - 3) goto failed;
    script = malloc((root_length + script_length) * sizeof(*script));
    if (!script) goto failed;
    wmemcpy(script, module, root_length);
    wmemcpy(script + root_length, script_path, script_length);
    /* This executable, -E, the script, then every argument after argv[0]. */
    count = argc + 2;
    argv = calloc((size_t)count + 1, sizeof(*argv));
    if (!argv || !(argv[0] = utf8(module))) goto failed;
    argv[1] = ignore_environment;
    if (!(argv[2] = utf8(script))) goto failed;
    for (index = 1; index < argc; ++index)
        if (!(argv[index + 2] = utf8(wide_argv[index]))) goto failed;
    status = titan_lua_main(count, argv);
    goto done;
failed:
    fprintf(stderr, "titanc: %s\n", failure);
done:
    if (argv) {
        for (index = 0; index < count; ++index)
            if (argv[index] != ignore_environment) free(argv[index]);
        free(argv);
    }
    free(module);
    free(script);
    return status;
}
