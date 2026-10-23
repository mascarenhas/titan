#ifndef TITAN_LUA_CLOSE_WORKER_POOL_H
#define TITAN_LUA_CLOSE_WORKER_POOL_H
/* Cross-thread counters for the lua_close_worker_pool_app child. Each cell is
 * a plain int in host-owned storage, updated by worker threads and nested
 * states, so every access is atomic. */
static inline int lua_close_pool_get(void *raw, int index) {
    int *cells = raw;
    return __atomic_load_n(&cells[index], __ATOMIC_ACQUIRE);
}
static inline void lua_close_pool_add(void *raw, int index) {
    int *cells = raw;
    __atomic_add_fetch(&cells[index], 1, __ATOMIC_ACQ_REL);
}
static inline void lua_close_pool_noop(void *raw) { (void)raw; }
#endif
