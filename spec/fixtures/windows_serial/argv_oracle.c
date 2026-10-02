/* Windows-only native oracle. Build with the selected CLANG64 compiler:
 * clang -std=c99 -municode argv_oracle.c -o argv_oracle.exe
 * wmain observes the actual UTF-16 arguments delivered to the executable;
 * its report explicitly converts them to UTF-8 independently of the ACP.
 */
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <wchar.h>
#include <io.h>
#include <fcntl.h>

static int report(FILE *output, int argc, wchar_t **argv) {
    int index;
    if (fprintf(output, "%d\n", argc) < 0) return 70;
    for (index = 0; index < argc; ++index) {
        int length = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
            argv[index], -1, NULL, 0, NULL, NULL);
        char *bytes;
        int offset;
        if (length == 0) return 71;
        bytes = (char *)malloc((size_t)length);
        if (bytes == NULL) return 72;
        if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, argv[index],
                -1, bytes, length, NULL, NULL) == 0) {
            free(bytes);
            return 73;
        }
        for (offset = 0; offset < length - 1; ++offset)
            if (fprintf(output, "%02x", (unsigned char)bytes[offset]) < 0) {
                free(bytes);
                return 74;
            }
        free(bytes);
        if (fputc('\n', output) == EOF) return 75;
    }
    return fflush(output) == 0 ? 0 : 76;
}

int wmain(int argc, wchar_t **argv) {
    if (_setmode(_fileno(stdout), _O_BINARY) == -1) return 77;
    if (_setmode(_fileno(stderr), _O_BINARY) == -1) return 78;
    if (argc < 2) return 79;
    if (wcscmp(argv[1], L"--argv") == 0)
        return report(stdout, argc - 2, argv + 2);
    if (wcscmp(argv[1], L"--record") == 0) {
        FILE *output;
        int status;
        if (argc < 3) return 80;
        output = _wfopen(argv[2], L"wb");
        if (output == NULL) return 81;
        status = report(output, argc - 3, argv + 3);
        if (fclose(output) != 0) return 82;
        return status;
    }
    if (wcscmp(argv[1], L"--exit") == 0) {
        if (argc != 3) return 83;
        return (int)wcstol(argv[2], NULL, 10);
    }
    if (wcscmp(argv[1], L"--bytes") == 0) {
        static const unsigned char bytes[] = { 'A', '\r', '\n', 'B', 0,
            'C', 26, 'D', 255 };
        if (fwrite(bytes, 1, sizeof(bytes), stdout) != sizeof(bytes) ||
            fflush(stdout) != 0) return 84;
        if (fwrite("stderr", 1, 6, stderr) != 6 || fflush(stderr) != 0) return 85;
        return 0;
    }
    if (wcscmp(argv[1], L"--locale") == 0) {
        const char *lang = getenv("LANG"), *all = getenv("LC_ALL");
        if (printf("%s|%s", lang != NULL ? lang : "", all != NULL ? all : "") < 0)
            return 86;
        return fflush(stdout) == 0 ? 0 : 87;
    }
    (void)report(stderr, argc, argv);
    return 88;
}
