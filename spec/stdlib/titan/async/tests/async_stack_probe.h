#ifndef TITAN_ASYNC_STACK_PROBE_H
#define TITAN_ASYNC_STACK_PROBE_H
#include <stdint.h>
#include <stddef.h>

typedef struct {
    uintptr_t low;
    uintptr_t high;
} AsyncStackProbe;

static inline void titan_async_stack_reset(AsyncStackProbe *probe) {
    probe->low = UINTPTR_MAX;
    probe->high = 0;
}

static inline void titan_async_stack_sample(AsyncStackProbe *probe) {
    /* Frame addresses avoid ASan relocation of automatic variables. */
    uintptr_t address = (uintptr_t)__builtin_frame_address(0);
    if (address < probe->low) probe->low = address;
    if (address > probe->high) probe->high = address;
}

static inline size_t titan_async_stack_span(const AsyncStackProbe *probe) {
    return (size_t)(probe->high - probe->low);
}
#endif
