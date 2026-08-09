#ifndef TITAN_SPEC_IO_FS_TIMER_NATIVE_SUPPORT_H
#define TITAN_SPEC_IO_FS_TIMER_NATIVE_SUPPORT_H

#include <errno.h>
#include <fcntl.h>
#include <stddef.h>
#include <stdlib.h>
#include <unistd.h>

/* Strict C99 hides these POSIX declarations on supported Unix hosts. */
extern int setenv(const char *, const char *, int);
extern int unsetenv(const char *);
extern int symlink(const char *, const char *);
extern char *mkdtemp(char *);

typedef unsigned long titan_spec_size;

static inline int titan_spec_capture_pipe(int descriptors[2])
{
    int flags;
    if (pipe(descriptors) != 0) return -1;
    flags = fcntl(descriptors[0], F_GETFL, 0);
    if (flags < 0 || fcntl(descriptors[0], F_SETFL, flags | O_NONBLOCK) < 0) {
        int saved_errno = errno;
        close(descriptors[0]);
        close(descriptors[1]);
        errno = saved_errno;
        return -1;
    }
    return 0;
}

static inline long titan_spec_capture_read(int descriptor,
                                           char *buffer,
                                           titan_spec_size count)
{
    return (long)read(descriptor, buffer, (size_t)count);
}

static inline int titan_spec_remove_if_present(const char *path)
{
    if (remove(path) == 0 || errno == ENOENT) return 0;
    return -1;
}

#endif
