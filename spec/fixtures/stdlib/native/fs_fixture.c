#define _POSIX_C_SOURCE 200809L
#if defined(__APPLE__) && !defined(_DARWIN_C_SOURCE)
#define _DARWIN_C_SOURCE
#endif
#define _CRT_RAND_S
#include <stddef.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <direct.h>
#include <windows.h>

static wchar_t *wide_path(const char *path)
{
    int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1,
                                     NULL, 0);
    if (length == 0) return NULL;
    wchar_t *wide = malloc((size_t)length * sizeof(*wide));
    if (wide != NULL && !MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                            path, -1, wide, length)) {
        free(wide);
        return NULL;
    }
    return wide;
}
#else
#include <unistd.h>
#endif

int titan_spec_mkdtemp(char *pattern)
{
#ifdef _WIN32
    size_t length = strlen(pattern);
    if (length < 6 || strcmp(pattern + length - 6, "XXXXXX") != 0) return -1;
    static const char alphabet[] = "abcdefghijklmnopqrstuvwxyz0123456789";
    for (int attempt = 0; attempt < 100; attempt++) {
        for (size_t index = length - 6; index < length; index++) {
            unsigned int random;
            if (rand_s(&random) != 0) return -1;
            pattern[index] = alphabet[random % (sizeof(alphabet) - 1)];
        }
        wchar_t *wide = wide_path(pattern);
        if (wide == NULL) return -1;
        int status = _wmkdir(wide);
        int saved_errno = errno;
        free(wide);
        if (status == 0) return 0;
        if (saved_errno != EEXIST) return -saved_errno;
    }
    return -EEXIST;
#else
    return mkdtemp(pattern) != NULL ? 0 : -errno;
#endif
}

int titan_spec_symlink(const char *target, const char *path, int directory)
{
#ifdef _WIN32
    wchar_t *wide_target = wide_path(target);
    wchar_t *wide_link = wide_path(path);
    if (wide_target == NULL || wide_link == NULL) {
        free(wide_target);
        free(wide_link);
        return -1;
    }
    DWORD flags = SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE;
    if (directory) flags |= SYMBOLIC_LINK_FLAG_DIRECTORY;
    int created = CreateSymbolicLinkW(wide_link, wide_target, flags);
    DWORD error = created ? ERROR_SUCCESS : GetLastError();
    free(wide_target);
    free(wide_link);
    if (error == ERROR_PRIVILEGE_NOT_HELD) return 1;
    return created ? 0 : -(int)error;
#else
    (void)directory;
    return symlink(target, path) == 0 ? 0 : -errno;
#endif
}

int titan_spec_remove_if_present(const char *path)
{
#ifdef _WIN32
    wchar_t *wide = wide_path(path);
    if (wide == NULL) return -1;
    int status = _wremove(wide);
    if (status != 0 && errno != ENOENT) status = _wrmdir(wide);
    int saved_errno = errno;
    free(wide);
    return status == 0 || saved_errno == ENOENT ? 0 : -saved_errno;
#else
    return remove(path) == 0 || errno == ENOENT ? 0 : -errno;
#endif
}

int titan_spec_write_file(const char *path, const char *contents, size_t length)
{
#ifdef _WIN32
    wchar_t *wide = wide_path(path);
    if (wide == NULL) return -1;
    FILE *file = _wfopen(wide, L"wb");
    free(wide);
#else
    FILE *file = fopen(path, "wb");
#endif
    if (file == NULL) return -1;
    int failed = length != 0 && fwrite(contents, 1, length, file) != length;
    if (fclose(file) != 0) failed = 1;
    return failed ? -1 : 0;
}
