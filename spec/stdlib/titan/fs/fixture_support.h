#ifndef TITAN_SPEC_FS_FIXTURE_SUPPORT_H
#define TITAN_SPEC_FS_FIXTURE_SUPPORT_H

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>

/* Strict C99 hides these POSIX declarations on supported Unix hosts. */
extern int setenv(const char *, const char *, int);
extern int unsetenv(const char *);
extern int symlink(const char *, const char *);
extern char *mkdtemp(char *);

static inline int titan_spec_remove_if_present(const char *path)
{
    if (remove(path) == 0 || errno == ENOENT) return 0;
    return -1;
}

static inline int titan_spec_write_file(
    const char *path, const char *contents, size_t length)
{
    FILE *file = fopen(path, "wb");
    if (file == NULL) return -1;
    int failed = length != 0 && fwrite(contents, 1, length, file) != length;
    if (fclose(file) != 0) failed = 1;
    return failed ? -1 : 0;
}

#endif
