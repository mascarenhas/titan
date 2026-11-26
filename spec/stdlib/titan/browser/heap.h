#ifndef TITAN_BROWSER_TEST_HEAP_H
#define TITAN_BROWSER_TEST_HEAP_H
#include <stddef.h>

/* The instance's current WebAssembly memory size in bytes. */
static inline size_t titan_test_heap_size(void) {
  return (size_t)__builtin_wasm_memory_size(0) * 65536U;
}
#endif
