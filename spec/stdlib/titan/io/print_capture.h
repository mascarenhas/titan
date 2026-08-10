#ifndef TITAN_SPEC_IO_PRINT_CAPTURE_H
#define TITAN_SPEC_IO_PRINT_CAPTURE_H

#include <errno.h>
#include <fcntl.h>
#include <stddef.h>
#include <unistd.h>

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

#endif
