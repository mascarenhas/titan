/* Compile the actual selected alloc.c, replacing only the allocation boundary.
   The always-moving shim makes vector growth work deterministic. */
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <limits.h>

#ifndef TITAN_ALLOC_SOURCE
#error "TITAN_ALLOC_SOURCE must name the actual verified alloc.c"
#endif

static const char *current_case;
static void fail_check(const char *expression, int line) {
  fprintf(stderr, "allocator probe failed: case=%s line=%d expression=%s\n",
          current_case, line, expression);
  exit(1);
}
#define CHECK(expression) do { if (!(expression)) fail_check(#expression, __LINE__); } while (0)

struct block { void *pointer; size_t capacity; };
struct allocator_metrics {
  struct block blocks[32];
  size_t calls, malloc_calls, free_calls, copied_bytes, requested_total;
  size_t requested_max, last_requested, failures, zero_reallocs, live;
  size_t fail_call;
};
static struct allocator_metrics allocator;

static size_t find_block(void *pointer) {
  size_t index;
  for (index = 0; index < sizeof allocator.blocks / sizeof allocator.blocks[0]; ++index)
    if (allocator.blocks[index].pointer == pointer) return index;
  fail_check("untracked live pointer", __LINE__);
  return 0;
}
static void *tracked_malloc(size_t requested) {
  size_t index;
  void *pointer = malloc(requested ? requested : 1);
  CHECK(pointer != NULL);
  ++allocator.malloc_calls;
  for (index = 0; index < sizeof allocator.blocks / sizeof allocator.blocks[0]; ++index)
    if (allocator.blocks[index].pointer == NULL) {
      allocator.blocks[index].pointer = pointer;
      allocator.blocks[index].capacity = requested;
      ++allocator.live;
      return pointer;
    }
  fail_check("tracked block table exhausted", __LINE__);
  return NULL;
}
static void tracked_free(void *pointer) {
  size_t index;
  if (pointer == NULL) return;
  index = find_block(pointer);
  allocator.blocks[index].pointer = NULL;
  allocator.blocks[index].capacity = 0;
  --allocator.live;
  ++allocator.free_calls;
  free(pointer);
}
static void *tracked_realloc(void *pointer, size_t requested) {
  size_t old_index = 0, old_capacity = 0, copied;
  void *next;
  ++allocator.calls;
  allocator.last_requested = requested;
  if (requested > allocator.requested_max) allocator.requested_max = requested;
  /* Enormous requests are observed but never sent to the real allocator. */
  if (allocator.calls == allocator.fail_call || requested > 64u * 1024u * 1024u) {
    ++allocator.failures; errno = ENOMEM; return NULL;
  }
  if (requested == 0) {
    ++allocator.zero_reallocs; errno = EINVAL; return NULL;
  }
  CHECK(allocator.requested_total <= SIZE_MAX - requested);
  allocator.requested_total += requested;
  if (pointer != NULL) {
    old_index = find_block(pointer);
    old_capacity = allocator.blocks[old_index].capacity;
  }
  next = tracked_malloc(requested);
  if (pointer != NULL) {
    /* Allocate before freeing: movement is guaranteed, independent of malloc. */
    CHECK(next != pointer);
    copied = old_capacity < requested ? old_capacity : requested;
    memcpy(next, pointer, copied);
    CHECK(allocator.copied_bytes <= SIZE_MAX - copied);
    allocator.copied_bytes += copied;
    tracked_free(pointer);
  }
  return next;
}

/* System headers above are already loaded, so their declarations are not
   rewritten. Only calls in the real source are redirected. */
#define malloc tracked_malloc
#define realloc tracked_realloc
#define free tracked_free
#include TITAN_ALLOC_SOURCE
#undef malloc
#undef realloc
#undef free

struct errors { size_t count; int code; const char *message; };
static void record_error(void *data, const char *message, int code) {
  struct errors *errors = (struct errors *) data;
  ++errors->count; errors->code = code; errors->message = message;
}
static void reset(const char *name) {
  CHECK(allocator.live == 0);
  memset(&allocator, 0, sizeof allocator);
  current_case = name;
}
static unsigned char pattern(size_t index) {
  return (unsigned char) ((index * 37u + index / 251u + 11u) & 255u);
}
static void verify_bytes(const struct backtrace_vector *vector) {
  size_t index;
  const unsigned char *bytes = (const unsigned char *) vector->base;
  for (index = 0; index < vector->size; ++index) CHECK(bytes[index] == pattern(index));
}
static void check_state(const struct backtrace_vector *vector,
                        const struct backtrace_vector *before) {
  CHECK(vector->base == before->base);
  CHECK(vector->size == before->size);
  CHECK(vector->alc == before->alc);
}
static void fill_append(struct backtrace_vector *vector, size_t amount) {
  struct errors errors = { 0, 0, NULL };
  size_t before = vector->size, calls = allocator.calls, index;
  unsigned char *append = (unsigned char *)
    backtrace_vector_grow(NULL, amount, record_error, &errors, vector);
  CHECK(append != NULL);
  CHECK(errors.count == 0);
  CHECK(vector->size == before + amount);
  CHECK(append == (unsigned char *) vector->base + before);
  CHECK(vector->alc == allocator.blocks[find_block(vector->base)].capacity - vector->size);
  /* Full verification only after moves; per-append verification would itself
     make the test quadratic. The final check verifies every retained byte. */
  if (allocator.calls != calls) {
    size_t saved = vector->size;
    vector->size = before; verify_bytes(vector); vector->size = saved;
  }
  for (index = 0; index < amount; ++index) append[index] = pattern(before + index);
}
static void dispose(struct backtrace_vector *vector) {
  backtrace_vector_free(NULL, vector, NULL, NULL);
  CHECK(vector->base == NULL && vector->size == 0 && vector->alc == 0);
  CHECK(allocator.live == 0);
  CHECK(allocator.zero_reallocs == 0);
}
static void passed(void) {
  printf("{\"case\":\"%s\",\"passed\":true,\"realloc_calls\":%llu,"
         "\"copied_bytes\":%llu,\"requested_capacity_max\":%llu,\"live_blocks\":%llu}\n",
         current_case, (unsigned long long) allocator.calls,
         (unsigned long long) allocator.copied_bytes,
         (unsigned long long) allocator.requested_max,
         (unsigned long long) allocator.live);
}

struct record { uint64_t words[8]; };
struct record_alignment { char byte; struct record value; };
static void test_growth(void) {
  struct backtrace_vector vector = { NULL, 0, 0 };
  const size_t total = 8u * 1024u * 1024u, record_size = sizeof(struct record);
  size_t index, limit = 4, rows = total / record_size;
  reset("growth-bounds");
  while (rows > 1) { rows = (rows + 1) / 2; ++limit; }
  for (index = 0; index < total / record_size; ++index) {
    fill_append(&vector, record_size);
    CHECK((uintptr_t) vector.base % offsetof(struct record_alignment, value) == 0);
    CHECK((uintptr_t) ((unsigned char *) vector.base + vector.size - record_size)
          % offsetof(struct record_alignment, value) == 0);
    /* Broad amortized bounds, independent of any exact capacity sequence. */
    CHECK(allocator.calls <= limit);
    CHECK(allocator.copied_bytes <= 4u * vector.size + 65536u);
  }
  CHECK(vector.size == total); verify_bytes(&vector); dispose(&vector); passed();
}
static void test_mixed(void) {
  struct backtrace_vector vector = { NULL, 0, 0 };
  size_t calls;
  reset("mixed-boundaries");
  fill_append(&vector, 32); fill_append(&vector, 4064);
  CHECK(vector.size == 4096);
  fill_append(&vector, 1);
  calls = allocator.calls; fill_append(&vector, vector.alc);
  CHECK(allocator.calls == calls && vector.alc == 0);
  fill_append(&vector, 1); fill_append(&vector, 50000);
  verify_bytes(&vector); dispose(&vector); passed();
}
static void test_grow_failure(void) {
  struct backtrace_vector vector = { NULL, 0, 0 }, before;
  struct errors errors = { 0, 0, NULL };
  size_t amount;
  reset("grow-failure-transaction");
  allocator.fail_call = allocator.calls + 1;
  CHECK(backtrace_vector_grow(NULL, 64, record_error, &errors, &vector) == NULL);
  CHECK(errors.count == 1 && errors.code == ENOMEM);
  CHECK(strcmp(errors.message, "realloc") == 0);
  CHECK(vector.base == NULL && vector.size == 0 && vector.alc == 0);
  fill_append(&vector, 64); before = vector; amount = vector.alc + 1;
  errors.count = 0; allocator.fail_call = allocator.calls + 1;
  CHECK(backtrace_vector_grow(NULL, amount, record_error, &errors, &vector) == NULL);
  CHECK(errors.count == 1 && errors.code == ENOMEM);
  check_state(&vector, &before); verify_bytes(&vector);
  fill_append(&vector, amount); verify_bytes(&vector); dispose(&vector);
  errors.count = 0; allocator.fail_call = allocator.calls + 1;
  CHECK(backtrace_vector_grow(NULL, 64, NULL, NULL, &vector) == NULL);
  CHECK(vector.base == NULL && vector.size == 0 && vector.alc == 0);
  CHECK(allocator.live == 0); passed();
}
static void test_release_failure(void) {
  struct backtrace_vector vector = { NULL, 0, 0 }, before;
  struct errors errors = { 0, 0, NULL };
  size_t live;
  reset("release-failure-transaction");
  fill_append(&vector, 64); before = vector; live = allocator.live;
  allocator.fail_call = allocator.calls + 1;
  CHECK(backtrace_vector_release(NULL, &vector, record_error, &errors) == 0);
  CHECK(errors.count == 1 && errors.code == ENOMEM);
  check_state(&vector, &before); CHECK(allocator.live == live); verify_bytes(&vector);
  CHECK(backtrace_vector_release(NULL, &vector, record_error, &errors) == 1);
  CHECK(vector.alc == 0);
  CHECK(allocator.blocks[find_block(vector.base)].capacity == vector.size);
  verify_bytes(&vector); dispose(&vector);
  /* read_line_info disposes the retained vector directly after shrink failure. */
  fill_append(&vector, 64); before = vector; errors.count = 0;
  allocator.fail_call = allocator.calls + 1;
  CHECK(backtrace_vector_release(NULL, &vector, record_error, &errors) == 0);
  CHECK(errors.count == 1 && errors.code == ENOMEM);
  check_state(&vector, &before); verify_bytes(&vector); dispose(&vector);
  fill_append(&vector, 64); before = vector;
  allocator.fail_call = allocator.calls + 1;
  CHECK(backtrace_vector_release(NULL, &vector, NULL, NULL) == 0);
  check_state(&vector, &before); verify_bytes(&vector);
  dispose(&vector); passed();
}
static void test_finish(void) {
  struct backtrace_vector vector = { NULL, 0, 0 }, before;
  struct errors errors = { 0, 0, NULL };
  unsigned char *result; size_t index;
  reset("finish-ownership");
  fill_append(&vector, 257);
  result = (unsigned char *) backtrace_vector_finish(NULL, &vector, record_error, &errors);
  CHECK(result != NULL && errors.count == 0);
  CHECK(vector.base == NULL && vector.size == 0 && vector.alc == 0);
  CHECK(allocator.blocks[find_block(result)].capacity == 257);
  for (index = 0; index < 257; ++index) CHECK(result[index] == pattern(index));
  tracked_free(result);
  fill_append(&vector, 257); before = vector; allocator.fail_call = allocator.calls + 1;
  CHECK(backtrace_vector_finish(NULL, &vector, record_error, &errors) == NULL);
  CHECK(errors.count == 1 && errors.code == ENOMEM);
  check_state(&vector, &before); verify_bytes(&vector); dispose(&vector); passed();
}
static void test_zero(void) {
  struct backtrace_vector vector = { NULL, 0, 0 }, before;
  struct errors errors = { 0, 0, NULL }; size_t calls;
  reset("zero-size"); before = vector;
  CHECK(backtrace_vector_grow(NULL, 0, record_error, &errors, &vector) == NULL);
  check_state(&vector, &before); CHECK(allocator.calls == 0 && errors.count == 0);
  fill_append(&vector, 64); before = vector; calls = allocator.calls;
  CHECK(backtrace_vector_grow(NULL, 0, record_error, &errors, &vector)
        == (unsigned char *) vector.base + vector.size);
  check_state(&vector, &before); CHECK(allocator.calls == calls && errors.count == 0);
  dispose(&vector);
  vector.base = tracked_malloc(64); vector.size = 0; vector.alc = 64; calls = allocator.calls;
  CHECK(backtrace_vector_release(NULL, &vector, record_error, &errors) == 1);
  CHECK(vector.base == NULL && vector.size == 0 && vector.alc == 0);
  CHECK(allocator.calls == calls && allocator.live == 0 && errors.count == 0);
  CHECK(backtrace_vector_release(NULL, &vector, record_error, &errors) == 1);
  CHECK(backtrace_vector_finish(NULL, &vector, record_error, &errors) == NULL);
  CHECK(allocator.calls == calls && allocator.zero_reallocs == 0 && errors.count == 0); passed();
}
static void test_overflow(void) {
  struct backtrace_vector vector = { NULL, 0, 0 }, before, synthetic;
  struct errors errors = { 0, 0, NULL }; size_t calls, requested;
  reset("size-overflow"); fill_append(&vector, 64); before = vector;
  synthetic = before; synthetic.size = SIZE_MAX - 15; synthetic.alc = 0; calls = allocator.calls;
  /* A baseline overflow control must also fail safely before pointer arithmetic. */
  allocator.fail_call = calls + 1;
  CHECK(backtrace_vector_grow(NULL, 16, record_error, &errors, &synthetic) == NULL);
  CHECK(allocator.calls == calls && errors.count == 1 && errors.code == ENOMEM);
  CHECK(synthetic.base == before.base && synthetic.size == SIZE_MAX - 15 && synthetic.alc == 0);
  errors.count = 0; allocator.fail_call = 0;
  CHECK(backtrace_vector_grow(NULL, 16, NULL, NULL, &synthetic) == NULL);
  CHECK(allocator.calls == calls);
  synthetic.base = NULL; synthetic.size = 0; synthetic.alc = 0;
  requested = SIZE_MAX / 32 + 1; errors.count = 0;
  CHECK(backtrace_vector_grow(NULL, requested, record_error, &errors, &synthetic) == NULL);
  CHECK(allocator.last_requested == requested && errors.count == 1 && errors.code == ENOMEM);
  CHECK(synthetic.base == NULL && synthetic.size == 0 && synthetic.alc == 0);
  synthetic = before; synthetic.size = SIZE_MAX / 2 + 1; synthetic.alc = 0;
  requested = synthetic.size + 1; errors.count = 0;
  CHECK(backtrace_vector_grow(NULL, 1, record_error, &errors, &synthetic) == NULL);
  CHECK(allocator.last_requested == requested && errors.count == 1 && errors.code == ENOMEM);
  CHECK(synthetic.base == before.base && synthetic.size == SIZE_MAX / 2 + 1 && synthetic.alc == 0);
  check_state(&vector, &before); verify_bytes(&vector); dispose(&vector); passed();
}

int main(int argc, char **argv) {
  const char *mode = argc > 1 ? argv[1] : "all";
  current_case = "initial-state";
  if (strcmp(mode, "release-failure") == 0) test_release_failure();
  else if (strcmp(mode, "growth") == 0) test_growth();
  else if (strcmp(mode, "overflow") == 0) test_overflow();
  else if (strcmp(mode, "all") == 0) {
    test_release_failure(); test_finish(); test_zero(); test_grow_failure();
    test_mixed(); test_overflow(); test_growth();
  } else { fprintf(stderr, "unknown allocator probe mode\n"); return 2; }
  CHECK(allocator.live == 0); return 0;
}
