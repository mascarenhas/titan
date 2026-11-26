#ifndef TITAN_BROWSER_RECORDS_HEAP_H
#define TITAN_BROWSER_RECORDS_HEAP_H
#include <stddef.h>

/* The instance's current WebAssembly memory size in bytes. */
static inline size_t records_heap_size(void) {
  return (size_t)__builtin_wasm_memory_size(0) * 65536U;
}

/* The usable bytes C has allocated and not yet freed, which records_heap.c's
 * allocator wrappers count (wasi-libc has no mallinfo). */
size_t records_heap_used(void);
#endif
