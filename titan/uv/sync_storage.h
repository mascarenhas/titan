#ifndef TITAN_ISSUE194_SYNC_STORAGE_H
#define TITAN_ISSUE194_SYNC_STORAGE_H
#include <uv.h>
/* Addressable embedded storage even where libuv uses a scalar typedef.
 * C guarantees a struct and its first member have the same address.
 * Only the opaque once initializer requires a helper below. No routing. */
typedef struct { uv_mutex_t native; } titan_issue194_mutex_storage;
typedef struct { uv_rwlock_t native; } titan_issue194_rwlock_storage;
typedef struct { uv_sem_t native; } titan_issue194_sem_storage;
typedef struct { uv_cond_t native; } titan_issue194_cond_storage;
typedef struct { uv_barrier_t native; } titan_issue194_barrier_storage;
typedef struct { uv_key_t native; } titan_issue194_key_storage;
typedef struct { uv_once_t native; } titan_issue194_once_storage;
/* UV_ONCE_INIT is a platform-dependent aggregate/scalar initializer, not an
 * imported FFI value. Initialize final owner storage before any call or borrow. */
static inline void titan_issue194_once_init(titan_issue194_once_storage *owner) {
    uv_once_t fresh = UV_ONCE_INIT;
    owner->native = fresh;
}
#endif
