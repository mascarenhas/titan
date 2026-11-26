/* Measurement-only allocator accounting for the records program, linked with
 * -Wl,--wrap=malloc,--wrap=calloc,--wrap=realloc,--wrap=free. */
#include <malloc.h>
#include <stdlib.h>
#include "records_heap.h"

static size_t used;

extern void *__real_malloc(size_t size);
extern void *__real_calloc(size_t count, size_t size);
extern void *__real_realloc(void *pointer, size_t size);
extern void __real_free(void *pointer);

void *__wrap_malloc(size_t size) {
  void *pointer = __real_malloc(size);
  if (pointer) used += malloc_usable_size(pointer);
  return pointer;
}

void *__wrap_calloc(size_t count, size_t size) {
  void *pointer = __real_calloc(count, size);
  if (pointer) used += malloc_usable_size(pointer);
  return pointer;
}

void __wrap_free(void *pointer) {
  if (pointer) used -= malloc_usable_size(pointer);
  __real_free(pointer);
}

/* A zero size frees, one of C's two permitted behaviors, so the count never
 * depends on which one the allocator chose. */
void *__wrap_realloc(void *pointer, size_t size) {
  size_t before;
  void *resized;
  if (size == 0) {
    __wrap_free(pointer);
    return NULL;
  }
  before = pointer ? malloc_usable_size(pointer) : 0;
  resized = __real_realloc(pointer, size);
  if (resized) used = used - before + malloc_usable_size(resized);
  return resized;
}

size_t records_heap_used(void) { return used; }
