#ifndef TITAN_TEST_HANDLE_TRANSFER_FIXTURE_H
#define TITAN_TEST_HANDLE_TRANSFER_FIXTURE_H

#include <stdlib.h>
#ifdef _WIN32
#include <fcntl.h>
#include <io.h>
#else
#include <unistd.h>
#endif

/* The test retains this allocation until both Lua wrappers have retired.
 * The pipe is a real OS resource; the counters make premature close observable
 * without dereferencing a freed resource after an assertion fails. */
typedef struct titan_test_record_handle {
    int descriptor;
    int close_calls;
    int finalizers;
} titan_test_record_handle;

static inline int titan_test_record_handle_close_fd(int descriptor) {
#ifdef _WIN32
    return _close(descriptor);
#else
    return close(descriptor);
#endif
}

static inline void *titan_test_record_handle_new(void) {
    int descriptors[2];
    unsigned char byte = 107;
    titan_test_record_handle *handle = calloc(1, sizeof(*handle));
    if (!handle) return NULL;
#ifdef _WIN32
    if (_pipe(descriptors, 256, _O_BINARY) != 0) {
#else
    if (pipe(descriptors) != 0) {
#endif
        free(handle);
        return NULL;
    }
#ifdef _WIN32
    int written = _write(descriptors[1], &byte, 1);
#else
    int written = (int)write(descriptors[1], &byte, 1);
#endif
    titan_test_record_handle_close_fd(descriptors[1]);
    if (written != 1) {
        titan_test_record_handle_close_fd(descriptors[0]);
        free(handle);
        return NULL;
    }
    handle->descriptor = descriptors[0];
    return handle;
}

static inline void titan_test_record_handle_close(void *pointer) {
    titan_test_record_handle *handle = pointer;
    handle->close_calls++;
    if (handle->descriptor >= 0) {
        titan_test_record_handle_close_fd(handle->descriptor);
        handle->descriptor = -1;
    }
}

static inline void titan_test_record_handle_finalized(void *pointer) {
    titan_test_record_handle *handle = pointer;
    handle->finalizers++;
}

static inline int titan_test_record_handle_finalizers(void *pointer) {
    return ((titan_test_record_handle *)pointer)->finalizers;
}

static inline int titan_test_record_handle_close_calls(void *pointer) {
    return ((titan_test_record_handle *)pointer)->close_calls;
}

static inline int titan_test_record_handle_read(void *pointer) {
    titan_test_record_handle *handle = pointer;
    unsigned char byte = 0;
    if (handle->descriptor < 0) return -1;
#ifdef _WIN32
    if (_read(handle->descriptor, &byte, 1) != 1) return -1;
#else
    if (read(handle->descriptor, &byte, 1) != 1) return -1;
#endif
    return byte;
}

static inline void titan_test_record_handle_destroy(void *pointer) {
    titan_test_record_handle *handle = pointer;
    if (handle->descriptor >= 0)
        titan_test_record_handle_close_fd(handle->descriptor);
    free(handle);
}

#endif
