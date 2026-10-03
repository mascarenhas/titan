#ifndef TITAN_SPEC_IO_PRINT_CAPTURE_H
#define TITAN_SPEC_IO_PRINT_CAPTURE_H

#include <errno.h>
#include <fcntl.h>
#include <stddef.h>
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <io.h>
#include <stdint.h>
#else
#include <unistd.h>
#endif

typedef size_t titan_spec_size;

static inline int titan_spec_capture_pipe(int descriptors[2])
{
#ifdef _WIN32
    return _pipe(descriptors, 4096, _O_BINARY | _O_NOINHERIT);
#else
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
#endif
}

static inline ptrdiff_t titan_spec_capture_read(int descriptor,
                                               char *buffer,
                                               titan_spec_size count)
{
#ifdef _WIN32
    HANDLE pipe = (HANDLE)_get_osfhandle(descriptor);
    DWORD available, received;
    if (!PeekNamedPipe(pipe, NULL, 0, NULL, &available, NULL)) {
        if (GetLastError() == ERROR_BROKEN_PIPE) return 0;
        errno = EIO;
        return -1;
    }
    if (available == 0) { errno = EAGAIN; return -1; }
    if ((size_t)available > count) available = (DWORD)count;
    if (!ReadFile(pipe, buffer, available, &received, NULL)) {
        errno = EIO;
        return -1;
    }
    return (ptrdiff_t)received;
#else
    return (ptrdiff_t)read(descriptor, buffer, count);
#endif
}

static inline int titan_spec_capture_duplicate(int descriptor)
{
#ifdef _WIN32
    return _dup(descriptor);
#else
    return dup(descriptor);
#endif
}

/* Normalize _dup2's zero success result and update the actual Windows stdio
 * handle used by libuv, as well as the CRT descriptor used by C stdio. */
static inline int titan_spec_capture_replace(int source, int destination)
{
#ifdef _WIN32
    static const DWORD kinds[3] = {
        STD_INPUT_HANDLE, STD_OUTPUT_HANDLE, STD_ERROR_HANDLE
    };
    if (_dup2(source, destination) != 0) return -1;
    if (destination >= 0 && destination < 3 &&
        !SetStdHandle(kinds[destination], (HANDLE)_get_osfhandle(destination))) {
        errno = EIO;
        return -1;
    }
    return destination;
#else
    return dup2(source, destination);
#endif
}

static inline int titan_spec_capture_close(int descriptor)
{
#ifdef _WIN32
    return _close(descriptor);
#else
    return close(descriptor);
#endif
}

#endif
