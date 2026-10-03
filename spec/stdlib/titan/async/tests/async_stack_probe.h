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
    volatile unsigned char marker = 0;
    uintptr_t address = (uintptr_t)&marker;
    if (address < probe->low) probe->low = address;
    if (address > probe->high) probe->high = address;
}

static inline size_t titan_async_stack_span(const AsyncStackProbe *probe) {
    return (size_t)(probe->high - probe->low);
}
#endif
