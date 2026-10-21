#ifndef TITAN_UV_EXTERNAL_WAKE_NATIVE_H
#define TITAN_UV_EXTERNAL_WAKE_NATIVE_H

#include <stddef.h>
#include <uv.h>

typedef struct titan_uv_external_wake_target titan_uv_external_wake_target;

enum {
  TITAN_UV_WAKE_RETIRED = 0,
  TITAN_UV_WAKE_PREPARED = 1,
  TITAN_UV_WAKE_ARMED = 2,
  TITAN_UV_WAKE_PENDING = 3,
  TITAN_UV_WAKE_DELIVERED = 4
};

/* At most one drain batch of reference-zero targets is retained per core. */
#define TITAN_UV_WAKE_TARGET_CACHE_LIMIT 64

typedef struct titan_uv_external_wake_core {
  /* First-member address identity permits a mutex borrow without a C shim. */
  uv_mutex_t mutex;
  uv_async_t *handle;
  size_t references;
  size_t registrations;
  size_t active_waits;
  titan_uv_external_wake_target *registered;
  titan_uv_external_wake_target *head;
  titan_uv_external_wake_target *tail;
  /* Unpinned, reference-zero targets; their next field forms a free stack. */
  titan_uv_external_wake_target *free_targets;
  size_t free_count;
} titan_uv_external_wake_core;

struct titan_uv_external_wake_target {
  titan_uv_external_wake_core *core;
  size_t references;
  unsigned long long identity;
  int phase;
  titan_uv_external_wake_target *registered_next;
  titan_uv_external_wake_target *registered_prev;
  titan_uv_external_wake_target *next;
  titan_uv_external_wake_target *prev;
};

#endif
