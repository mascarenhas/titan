/* Native entry for the unchanged installed titanc.lua script.  Link the
 * configured upstream lua.c front end with -Dmain=titan_lua_main, and the
 * single controlled Lua DLL; no Lua engine is compiled into this executable.
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <wchar.h>

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
    wchar_t *module = NULL, *script = NULL;
    char **argv = NULL;
    int status = EXIT_FAILURE;
    DWORD capacity = 512;
    if (argc < 1 || argc > INT_MAX - 2) goto failed;
    for (;;) {
        module = malloc((size_t)capacity * sizeof(*module));
        if (!module) goto failed;
        DWORD length = GetModuleFileNameW(NULL, module, capacity);
        if (!length) goto failed;
        if (length < capacity) break;
        free(module);
        module = NULL;
        if (capacity == 32768) goto failed;
        capacity *= 2;
    }
    argv = calloc((size_t)argc + 2, sizeof(*argv));
    if (!argv || !(argv[0] = utf8(module))) goto failed;
    wchar_t *separator = wcsrchr(module, L'\\');
    if (!separator) goto failed;
    size_t directory = (size_t)(separator + 1 - module);
    script = malloc((directory + 11) * sizeof(*script));
    if (!script) goto failed;
    wmemcpy(script, module, directory);
    wcscpy(script + directory, L"titanc.lua");
    if (!(argv[1] = utf8(script))) goto failed;
    for (int i = 1; i < argc; ++i)
        if (!(argv[i + 1] = utf8(wide_argv[i]))) goto failed;
    status = titan_lua_main(argc + 1, argv);
    goto done;
failed:
    fputs("titanc: cannot prepare native UTF-8 command line\n", stderr);
done:
    if (argv) {
        for (int i = 0; i < argc + 1; ++i) free(argv[i]);
        free(argv);
    }
    free(module);
    free(script);
    return status;
}
