#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "rtt_probe.h"

#include <lua.h>
#include <lauxlib.h>
#include <uv.h>
#include <minicoro.h>
#if defined(__linux__)
#include <malloc.h>
#endif
#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <time.h>

#ifndef RTT_PROBE_WRAPPERS
#define RTT_PROBE_WRAPPERS 0
#endif

#if RTT_PROBE_WRAPPERS
extern void *__real_malloc(size_t size);
extern void *__real_calloc(size_t nmemb, size_t size);
extern void *__real_realloc(void *ptr, size_t size);
extern void __real_free(void *ptr);
extern void *__real_memcpy(void *dst, const void *src, size_t n);
extern void *__real_memmove(void *dst, const void *src, size_t n);
extern lua_State *__real_lua_newstate(lua_Alloc f, void *ud, unsigned int seed);
extern void __real_lua_close(lua_State *L);
extern int __real_uv_async_init(uv_loop_t *loop, uv_async_t *async, uv_async_cb async_cb);
extern int __real_uv_async_send(uv_async_t *async);
extern void __real_uv_close(uv_handle_t *handle, uv_close_cb close_cb);
extern int __real_uv_loop_close(uv_loop_t *loop);
extern mco_result __real_mco_yield(mco_coro *co, void *tag);

/* Check both __real declarations and __wrap definitions against this SDK, not
 * an ABI-erased approximation that happens to work on one calling convention. */
#define RTT_ASSERT_WRAPPER(name) \
  extern __typeof__(name) __wrap_##name; \
  _Static_assert(__builtin_types_compatible_p(__typeof__(&__real_##name), \
                  __typeof__(&name)), "pinned SDK ABI mismatch: " #name)
RTT_ASSERT_WRAPPER(malloc);
RTT_ASSERT_WRAPPER(calloc);
RTT_ASSERT_WRAPPER(realloc);
RTT_ASSERT_WRAPPER(free);
RTT_ASSERT_WRAPPER(memcpy);
RTT_ASSERT_WRAPPER(memmove);
RTT_ASSERT_WRAPPER(lua_newstate);
RTT_ASSERT_WRAPPER(lua_close);
RTT_ASSERT_WRAPPER(uv_async_init);
RTT_ASSERT_WRAPPER(uv_async_send);
RTT_ASSERT_WRAPPER(uv_close);
RTT_ASSERT_WRAPPER(uv_loop_close);
RTT_ASSERT_WRAPPER(mco_yield);
#undef RTT_ASSERT_WRAPPER

static void *raw_calloc(size_t nmemb, size_t size) {
  return __real_calloc(nmemb, size);
}
static void raw_free(void *ptr) {
  __real_free(ptr);
}

static size_t block_usable_size(void *ptr) {
  if (ptr == NULL) return 0;
#if defined(__linux__)
  return malloc_usable_size(ptr);
#else
  return 0;
#endif
}
#else
static void *raw_calloc(size_t nmemb, size_t size) {
  return calloc(nmemb, size);
}
static void raw_free(void *ptr) {
  free(ptr);
}
#endif

typedef struct {
  uint64_t lua_alloc_calls;
  uint64_t lua_realloc_calls;
  uint64_t lua_free_calls;
  uint64_t lua_requested_bytes;
  int64_t lua_live_delta_bytes;

  uint64_t native_malloc_calls;
  uint64_t native_calloc_calls;
  uint64_t native_realloc_calls;
  uint64_t native_free_calls;
  uint64_t native_requested_bytes;
  int64_t native_live_blocks;
  int64_t native_usable_live_bytes;
  int64_t native_usable_peak_bytes;

  uint64_t outside_lua_alloc_memcpy_calls;
  uint64_t outside_lua_alloc_memcpy_bytes;
  uint64_t inside_lua_alloc_memcpy_calls;
  uint64_t inside_lua_alloc_memcpy_bytes;

  uint64_t uv_async_init_calls;
  uint64_t uv_async_send_calls;
  uint64_t uv_async_close_calls;
  uint64_t uv_close_total_calls;
  uint64_t uv_async_close_callbacks;
  uint64_t uv_loop_close_calls;
  uint64_t uv_loop_close_successes;
  uint64_t uv_async_loop_retirements;

  uint64_t fast_successes;
  uint64_t slow_path_attempts;
  uint64_t registration_recheck_successes;
  uint64_t actual_suspensions;
  uint64_t notifications;
  uint64_t cancellations;
  uint64_t attributed_wakes;
  uint64_t unattributed_wakes;
} rtt_counters_snapshot_t;

typedef struct {
  _Atomic int64_t permit_start;
  _Atomic int producer;
  _Atomic int lane;
  _Atomic int64_t t0_send_start;
  _Atomic int64_t t1_send_done;
  _Atomic int64_t t2_worker_recv;
  _Atomic int64_t t3_reply_start;
  _Atomic int64_t t4_reply_done;
  _Atomic int64_t t5_reply_recv;
} rtt_op_trace_t;

typedef struct {
  uint64_t *values;
  _Atomic size_t count;
  _Atomic size_t truncated;
  size_t capacity;
} rtt_sample_buf_t;

typedef struct {
  _Atomic int in_use;
  int op_kind;
  int64_t op_start_ns;
  int64_t first_attempt_ns;
  int64_t dequeue_done_ns;
  int64_t slow_check_done_ns;
} rtt_active_op_t;

#define MAX_ACTIVE_OPS 512
#define MAX_MPMC_CONSUMERS 64
static rtt_active_op_t g_active_ops[MAX_ACTIVE_OPS];
static _Thread_local int tls_current_op_slot = -1;
static _Atomic int64_t g_resources[3];
static int64_t g_resources_start[3];
static int64_t g_lua_states_start;
static _Atomic uint64_t g_join_suspensions[2];
static uint64_t g_join_suspensions_start[2];
static uint64_t g_join_suspensions_stop[2];
static int g_setup_started;

void rtt_probe_resource(int kind, int delta) {
  if (kind >= 1 && kind <= 3)
    atomic_fetch_add_explicit(&g_resources[kind - 1], delta, memory_order_release);
}

int rtt_probe_quiesce(void) {
  int64_t deadline = rtt_probe_now_ns() + 30000000000LL;
  while (atomic_load_explicit(&g_resources[2], memory_order_acquire) != 0) {
    if (rtt_probe_now_ns() >= deadline) return 0;
    struct timespec pause = {0, 1000000};
    nanosleep(&pause, NULL);
  }
  return 1;
}


#if RTT_PROBE_WRAPPERS
#define MAX_ASYNC_HANDLES 16384
#define MAX_LUA_STATES 4096

typedef struct {
  _Atomic int in_use;
  _Atomic(lua_State *) state;
  lua_Alloc orig_alloc;
  void *orig_ud;
} rtt_lua_state_slot_t;

typedef struct {
  uv_handle_t *handle;
  uv_loop_t *loop;
  uv_close_cb close_cb;
} rtt_async_handle_entry_t;

typedef struct {
  _Atomic(void *) waiter;
  _Atomic int64_t notified_ns;
  _Atomic unsigned notifications;
  int cleanup;
  int post_yield;
  int suspended;
  int op_slot;
  void *target;
} rtt_waiter_entry_t;

static rtt_lua_state_slot_t g_lua_slots[MAX_LUA_STATES];
static rtt_async_handle_entry_t g_async_handles[MAX_ASYNC_HANDLES];
/* High-water bound, not a live count; protected by the registry lock. */
static size_t g_async_handles_used;
static atomic_flag g_async_handles_guard = ATOMIC_FLAG_INIT;

/* Publish each native handle/loop/callback identity together. Never call libuv
 * or a user callback while holding this private bounded-registry lock. */
static void rtt_async_handles_lock(void) {
  while (atomic_flag_test_and_set_explicit(&g_async_handles_guard, memory_order_acquire)) {}
}

static void rtt_async_handles_unlock(void) {
  atomic_flag_clear_explicit(&g_async_handles_guard, memory_order_release);
}
static rtt_waiter_entry_t g_waiters[MAX_ACTIVE_OPS];
static _Thread_local void *tls_pending_waiter;
static _Thread_local int tls_pending_kind;
static rtt_waiter_entry_t *find_waiter(void *waiter);

/* Only the underlying Lua allocator is excluded from the native ledger.
 * Libuv operations, finalizers and native packet cleanup are never suppressed. */
static _Thread_local int tls_in_lua_alloc = 0;
#endif

static void live_probe_owners(int64_t *states, int64_t *handles, int64_t *waiters) {
  *states = 0; *handles = 0; *waiters = 0;
#if RTT_PROBE_WRAPPERS
  for (int i = 0; i < MAX_LUA_STATES; i++)
    if (atomic_load_explicit(&g_lua_slots[i].in_use, memory_order_acquire)) (*states)++;
  rtt_async_handles_lock();
  for (size_t i = 0; i < g_async_handles_used; i++)
    if (g_async_handles[i].handle != NULL) (*handles)++;
  rtt_async_handles_unlock();
  for (int i = 0; i < MAX_ACTIVE_OPS; i++)
    if (atomic_load_explicit(&g_waiters[i].waiter, memory_order_acquire) != NULL) (*waiters)++;
#endif
}

static struct {
  _Atomic int initialized;
  _Atomic int instrumented;
  _Atomic int active_body;

  _Atomic uint64_t slot_exhaustion_failures;
  int calibration_ran;
  int calibration_passed;
  int64_t cal_lua_birth_allocs;
  int64_t cal_lua_birth_native_leak_allocs;
  int64_t cal_lua_post_close_delta_bytes;
  int64_t cal_native_cycle_blocks_delta;
  int64_t cal_native_cycle_usable_delta;

  int64_t payload_wire_bytes_per_op;
  int64_t cold_init_ns;
  int64_t warmup_ns;
  int64_t warmup_ops;
  int64_t setup_start_wall_ns;
  int64_t body_start_wall_ns;
  int64_t body_start_cpu_ns;
  int64_t body_stop_wall_ns;
  int64_t body_stop_cpu_ns;
  int64_t workers_retired_wall_ns;
  int64_t gc1_wall_ns;
  int64_t gc2_wall_ns;

  int64_t setup_start_lua_bytes;
  int64_t body_start_lua_bytes;
  int64_t body_stop_lua_bytes;
  int64_t workers_retired_lua_bytes;
  int64_t post_gc1_lua_bytes;
  int64_t post_gc2_lua_bytes;

  _Atomic uint64_t lua_alloc_calls;
  _Atomic uint64_t lua_realloc_calls;
  _Atomic uint64_t lua_free_calls;
  _Atomic uint64_t lua_requested_bytes;
  _Atomic int64_t lua_live_delta_bytes;

  _Atomic uint64_t native_malloc_calls;
  _Atomic uint64_t native_calloc_calls;
  _Atomic uint64_t native_realloc_calls;
  _Atomic uint64_t native_free_calls;
  _Atomic uint64_t native_requested_bytes;
  _Atomic int64_t native_live_blocks;
  _Atomic int64_t native_usable_live_bytes;
  _Atomic int64_t native_usable_peak_bytes;

  _Atomic uint64_t outside_lua_alloc_memcpy_calls;
  _Atomic uint64_t outside_lua_alloc_memcpy_bytes;
  _Atomic uint64_t inside_lua_alloc_memcpy_calls;
  _Atomic uint64_t inside_lua_alloc_memcpy_bytes;

  _Atomic uint64_t uv_async_init_calls;
  _Atomic uint64_t uv_async_send_calls;
  _Atomic uint64_t uv_async_close_calls;
  _Atomic uint64_t uv_close_total_calls;
  _Atomic uint64_t uv_async_close_callbacks;
  _Atomic uint64_t uv_loop_close_calls;
  _Atomic uint64_t uv_loop_close_successes;
  _Atomic uint64_t uv_async_loop_retirements;

  _Atomic uint64_t fast_successes;
  _Atomic uint64_t slow_path_attempts;
  _Atomic uint64_t registration_recheck_successes;
  _Atomic uint64_t actual_suspensions;
  _Atomic uint64_t notifications;
  _Atomic uint64_t cancellations;
  _Atomic uint64_t attributed_wakes;
  _Atomic uint64_t unattributed_wakes;


  rtt_counters_snapshot_t snap_setup_start;
  rtt_counters_snapshot_t snap_body_start;
  rtt_counters_snapshot_t snap_body_stop;
  rtt_counters_snapshot_t snap_workers_retired;
  rtt_counters_snapshot_t snap_post_gc1;
  rtt_counters_snapshot_t snap_post_gc2;

  rtt_sample_buf_t rtt_samples;
  rtt_sample_buf_t sender_encode_samples;
  rtt_sample_buf_t queue_admission_samples;
  rtt_sample_buf_t wait_registration_samples;
  rtt_sample_buf_t native_wake_samples;
  rtt_sample_buf_t receiver_decode_samples;
  rtt_sample_buf_t reply_processing_samples;
  rtt_sample_buf_t req_one_way_samples;
  rtt_sample_buf_t reply_one_way_samples;

  rtt_op_trace_t *op_traces;
  size_t trace_capacity;
  int64_t mpmc_operations;
  int mpmc_producers;
  int mpmc_lanes;
  int mpmc_consumers;
  _Atomic int mpmc_trace_failures;
  int64_t consumer_operations[MAX_MPMC_CONSUMERS];
} g_probe;

static int64_t clock_ns(clockid_t clk) {
  struct timespec ts;
  if (clock_gettime(clk, &ts) != 0) return 0;
  return (int64_t)ts.tv_sec * 1000000000LL + (int64_t)ts.tv_nsec;
}

int64_t rtt_probe_now_ns(void) {
  return clock_ns(CLOCK_MONOTONIC);
}

#if RTT_PROBE_WRAPPERS
static void update_peak_usable(int64_t current) {
  int64_t prev = atomic_load_explicit(&g_probe.native_usable_peak_bytes, memory_order_relaxed);
  while (current > prev) {
    if (atomic_compare_exchange_weak_explicit(
            &g_probe.native_usable_peak_bytes, &prev, current,
            memory_order_relaxed, memory_order_relaxed)) {
      break;
    }
  }
}
#endif

static void take_snapshot(rtt_counters_snapshot_t *dst) {
  dst->lua_alloc_calls = atomic_load_explicit(&g_probe.lua_alloc_calls, memory_order_relaxed);
  dst->lua_realloc_calls = atomic_load_explicit(&g_probe.lua_realloc_calls, memory_order_relaxed);
  dst->lua_free_calls = atomic_load_explicit(&g_probe.lua_free_calls, memory_order_relaxed);
  dst->lua_requested_bytes = atomic_load_explicit(&g_probe.lua_requested_bytes, memory_order_relaxed);
  dst->lua_live_delta_bytes = atomic_load_explicit(&g_probe.lua_live_delta_bytes, memory_order_relaxed);

  dst->native_malloc_calls = atomic_load_explicit(&g_probe.native_malloc_calls, memory_order_relaxed);
  dst->native_calloc_calls = atomic_load_explicit(&g_probe.native_calloc_calls, memory_order_relaxed);
  dst->native_realloc_calls = atomic_load_explicit(&g_probe.native_realloc_calls, memory_order_relaxed);
  dst->native_free_calls = atomic_load_explicit(&g_probe.native_free_calls, memory_order_relaxed);
  dst->native_requested_bytes = atomic_load_explicit(&g_probe.native_requested_bytes, memory_order_relaxed);
  dst->native_live_blocks = atomic_load_explicit(&g_probe.native_live_blocks, memory_order_relaxed);
  dst->native_usable_live_bytes = atomic_load_explicit(&g_probe.native_usable_live_bytes, memory_order_relaxed);
  dst->native_usable_peak_bytes = atomic_load_explicit(&g_probe.native_usable_peak_bytes, memory_order_relaxed);

  dst->outside_lua_alloc_memcpy_calls =
      atomic_load_explicit(&g_probe.outside_lua_alloc_memcpy_calls, memory_order_relaxed);
  dst->outside_lua_alloc_memcpy_bytes =
      atomic_load_explicit(&g_probe.outside_lua_alloc_memcpy_bytes, memory_order_relaxed);
  dst->inside_lua_alloc_memcpy_calls =
      atomic_load_explicit(&g_probe.inside_lua_alloc_memcpy_calls, memory_order_relaxed);
  dst->inside_lua_alloc_memcpy_bytes =
      atomic_load_explicit(&g_probe.inside_lua_alloc_memcpy_bytes, memory_order_relaxed);

  dst->uv_async_init_calls = atomic_load_explicit(&g_probe.uv_async_init_calls, memory_order_relaxed);
  dst->uv_async_send_calls = atomic_load_explicit(&g_probe.uv_async_send_calls, memory_order_relaxed);
  dst->uv_async_close_calls = atomic_load_explicit(&g_probe.uv_async_close_calls, memory_order_relaxed);
  dst->uv_close_total_calls = atomic_load_explicit(&g_probe.uv_close_total_calls, memory_order_relaxed);
  dst->uv_async_close_callbacks = atomic_load_explicit(&g_probe.uv_async_close_callbacks, memory_order_relaxed);
  dst->uv_loop_close_calls = atomic_load_explicit(&g_probe.uv_loop_close_calls, memory_order_relaxed);
  dst->uv_loop_close_successes = atomic_load_explicit(&g_probe.uv_loop_close_successes, memory_order_relaxed);
  dst->uv_async_loop_retirements = atomic_load_explicit(&g_probe.uv_async_loop_retirements, memory_order_relaxed);

  dst->fast_successes = atomic_load_explicit(&g_probe.fast_successes, memory_order_relaxed);
  dst->slow_path_attempts = atomic_load_explicit(&g_probe.slow_path_attempts, memory_order_relaxed);
  dst->registration_recheck_successes =
      atomic_load_explicit(&g_probe.registration_recheck_successes, memory_order_relaxed);
  dst->actual_suspensions = atomic_load_explicit(&g_probe.actual_suspensions, memory_order_relaxed);
  dst->notifications = atomic_load_explicit(&g_probe.notifications, memory_order_relaxed);
  dst->cancellations = atomic_load_explicit(&g_probe.cancellations, memory_order_relaxed);
  dst->attributed_wakes = atomic_load_explicit(&g_probe.attributed_wakes, memory_order_relaxed);
  dst->unattributed_wakes = atomic_load_explicit(&g_probe.unattributed_wakes, memory_order_relaxed);
}


#if RTT_PROBE_WRAPPERS
/* Private accounting calibration:
 * 1. Verifies linker --wrap hooks for malloc, realloc, free, memcpy are hit and
 *    a known 4096 -> 8192 -> free cycle balances to 0 live blocks and 0 usable bytes.
 * 2. Verifies luaL_newstate -> __wrap_lua_newstate installs rtt_lua_alloc BEFORE
 *    the first Lua state allocation so zero Lua birth allocations leak into the
 *    native allocator ledger, and __wrap_lua_close returns Lua live delta to 0. */
static int run_accounting_calibration(void) {
  static void *(*volatile v_malloc)(size_t) = malloc;
  static void *(*volatile v_realloc)(void *, size_t) = realloc;
  static void (*volatile v_free)(void *) = free;
  static void *(*volatile v_memcpy)(void *, const void *, size_t) = memcpy;
  static lua_State *(*volatile v_luaL_newstate)(void) = luaL_newstate;
  static void (*volatile v_lua_close)(lua_State *) = lua_close;

  atomic_store_explicit(&g_probe.active_body, 1, memory_order_release);

  rtt_counters_snapshot_t s0, s1, s2, s3;
  take_snapshot(&s0);

  char src_buf[256];
  for (int i = 0; i < 256; i++) src_buf[i] = (char)(i & 0x7f);

  void *p1 = v_malloc(4096);
  if (p1 == NULL) return 0;
  v_memcpy(p1, src_buf, 256);
  void *p2 = v_realloc(p1, 8192);
  if (p2 == NULL) {
    v_free(p1);
    return 0;
  }
  v_free(p2);
  take_snapshot(&s1);

  int64_t nat_malloc_hits = (int64_t)(s1.native_malloc_calls - s0.native_malloc_calls);
  int64_t nat_realloc_hits = (int64_t)(s1.native_realloc_calls - s0.native_realloc_calls);
  int64_t nat_free_hits = (int64_t)(s1.native_free_calls - s0.native_free_calls);
  int64_t nat_memcpy_hits = (int64_t)(s1.outside_lua_alloc_memcpy_calls - s0.outside_lua_alloc_memcpy_calls);
  int64_t nat_blocks_delta = s1.native_live_blocks - s0.native_live_blocks;
  int64_t nat_usable_delta = s1.native_usable_live_bytes - s0.native_usable_live_bytes;

  g_probe.cal_native_cycle_blocks_delta = nat_blocks_delta;
  g_probe.cal_native_cycle_usable_delta = nat_usable_delta;

  if (nat_malloc_hits != 1 || nat_realloc_hits != 1 || nat_free_hits != 1 ||
      nat_memcpy_hits < 1 || nat_blocks_delta != 0 || nat_usable_delta != 0) {
    atomic_store_explicit(&g_probe.active_body, 0, memory_order_release);
    return 0;
  }

  lua_State *cal_L = v_luaL_newstate();
  if (cal_L == NULL) {
    atomic_store_explicit(&g_probe.active_body, 0, memory_order_release);
    return 0;
  }
  take_snapshot(&s2);

  int64_t lua_birth_allocs = (int64_t)(s2.lua_alloc_calls - s1.lua_alloc_calls);
  int64_t lua_birth_native_leaks =
      (int64_t)((s2.native_malloc_calls - s1.native_malloc_calls) +
                (s2.native_calloc_calls - s1.native_calloc_calls) +
                (s2.native_realloc_calls - s1.native_realloc_calls));

  v_lua_close(cal_L);
  take_snapshot(&s3);

  int64_t lua_post_close_delta = s3.lua_live_delta_bytes - s1.lua_live_delta_bytes;
  int64_t nat_post_close_blocks = s3.native_live_blocks - s1.native_live_blocks;

  g_probe.cal_lua_birth_allocs = lua_birth_allocs;
  g_probe.cal_lua_birth_native_leak_allocs = lua_birth_native_leaks;
  g_probe.cal_lua_post_close_delta_bytes = lua_post_close_delta;

  atomic_store_explicit(&g_probe.active_body, 0, memory_order_release);

  if (lua_birth_allocs <= 0 || lua_birth_native_leaks != 0 ||
      lua_post_close_delta != 0 || nat_post_close_blocks != 0 ||
      atomic_load_explicit(&g_probe.slot_exhaustion_failures, memory_order_relaxed) != 0) {
    return 0;
  }
  g_probe.calibration_ran = 1;
  g_probe.calibration_passed = 1;
  return 1;
}
#endif

static int init_sample_buf(rtt_sample_buf_t *buf, size_t capacity) {
  buf->values = NULL;
  atomic_store_explicit(&buf->count, 0, memory_order_relaxed);
  atomic_store_explicit(&buf->truncated, 0, memory_order_relaxed);
  buf->capacity = capacity;
  if (capacity == 0) return 1;
  buf->values = (uint64_t *)raw_calloc(capacity, sizeof(uint64_t));
  return buf->values != NULL;
}

static void free_sample_buf(rtt_sample_buf_t *buf) {
  if (buf->values != NULL) {
    raw_free(buf->values);
    buf->values = NULL;
  }
  buf->capacity = 0;
  atomic_store_explicit(&buf->count, 0, memory_order_relaxed);
  atomic_store_explicit(&buf->truncated, 0, memory_order_relaxed);
}

static void push_sample(rtt_sample_buf_t *buf, int64_t ns) {
  if (ns < 0 || buf->capacity == 0 || buf->values == NULL) return;
  size_t idx = atomic_fetch_add_explicit(&buf->count, 1, memory_order_relaxed);
  if (idx < buf->capacity) {
    buf->values[idx] = (uint64_t)ns;
  } else {
    atomic_fetch_add_explicit(&buf->truncated, 1, memory_order_relaxed);
  }
}

int rtt_probe_init(int64_t sample_capacity, int64_t trace_capacity,
                   int instrumented) {
  rtt_probe_cleanup();
  if (!rtt_probe_quiesce()) return 0;
  g_setup_started = 0;
  g_probe.mpmc_operations = 0;
  atomic_store_explicit(&g_probe.mpmc_trace_failures, 0, memory_order_relaxed);
  size_t scap = sample_capacity > 0 ? (size_t)sample_capacity : 0;
  size_t tcap = trace_capacity > 0 ? (size_t)trace_capacity : 0;

  if (!init_sample_buf(&g_probe.rtt_samples, scap)) return 0;
  if (instrumented) {
    if (!init_sample_buf(&g_probe.sender_encode_samples, scap * 4) ||
        !init_sample_buf(&g_probe.queue_admission_samples, scap * 64) ||
        !init_sample_buf(&g_probe.wait_registration_samples, scap * 16) ||
        !init_sample_buf(&g_probe.native_wake_samples, scap * 16) ||
        !init_sample_buf(&g_probe.receiver_decode_samples, scap * 4) ||
        !init_sample_buf(&g_probe.reply_processing_samples, scap) ||
        !init_sample_buf(&g_probe.req_one_way_samples, scap) ||
        !init_sample_buf(&g_probe.reply_one_way_samples, scap)) {
      rtt_probe_cleanup();
      return 0;
    }
    if (tcap > 0) {
      g_probe.op_traces = (rtt_op_trace_t *)raw_calloc(tcap + 1, sizeof(rtt_op_trace_t));
      if (g_probe.op_traces == NULL) {
        rtt_probe_cleanup();
        return 0;
      }
      g_probe.trace_capacity = tcap;
    }
  }
  for (int i = 0; i < MAX_ACTIVE_OPS; i++) {
    atomic_store_explicit(&g_active_ops[i].in_use, 0, memory_order_relaxed);
  }
  /* State/handle slots and cumulative allocation ledgers span process birth
   * through terminal close. Never reset a live object's accounting here. */

  g_probe.payload_wire_bytes_per_op = 0;
  g_probe.calibration_ran = 0;
  g_probe.calibration_passed = 0;
  atomic_store_explicit(&g_probe.instrumented, instrumented ? 1 : 0, memory_order_relaxed);
  atomic_store_explicit(&g_probe.active_body, 0, memory_order_relaxed);

#if RTT_PROBE_WRAPPERS
  if (instrumented) {
    if (!run_accounting_calibration()) {
      rtt_probe_cleanup();
      return 0;
    }
  }
#endif

  atomic_store_explicit(&g_probe.initialized, 1, memory_order_release);
  return 1;
}

int rtt_probe_mpmc_setup(int64_t operations, int producers, int lanes, int consumers) {
  if (operations < 1 || operations > 1000000 || producers < 1 || lanes < 1 ||
      consumers < 1 || consumers > MAX_MPMC_CONSUMERS ||
      producers > MAX_ACTIVE_OPS / lanes || g_probe.mpmc_operations != 0) return 0;
  if (g_probe.op_traces == NULL) {
    g_probe.op_traces = raw_calloc((size_t)operations + 1, sizeof(rtt_op_trace_t));
    if (g_probe.op_traces == NULL) return 0;
    g_probe.trace_capacity = (size_t)operations;
  }
  if (g_probe.trace_capacity < (size_t)operations) return 0;
  g_probe.mpmc_operations = operations;
  g_probe.mpmc_producers = producers;
  g_probe.mpmc_lanes = lanes;
  g_probe.mpmc_consumers = consumers;
  for (int i = 0; i < consumers; i++) g_probe.consumer_operations[i] = -1;
  return 1;
}

void rtt_probe_trace_permit_start(int64_t req_id, int producer, int lane, int64_t t_ns) {
  if (req_id < 1 || req_id > g_probe.mpmc_operations ||
      producer < 1 || producer > g_probe.mpmc_producers ||
      lane < 1 || lane > g_probe.mpmc_lanes ||
      !atomic_load_explicit(&g_probe.active_body, memory_order_acquire)) {
    atomic_fetch_add_explicit(&g_probe.mpmc_trace_failures, 1, memory_order_relaxed);
    return;
  }
  rtt_op_trace_t *trace = &g_probe.op_traces[req_id];
  if (atomic_exchange_explicit(&trace->permit_start, t_ns, memory_order_relaxed) != 0)
    atomic_fetch_add_explicit(&g_probe.mpmc_trace_failures, 1, memory_order_relaxed);
  atomic_store_explicit(&trace->producer, producer, memory_order_relaxed);
  atomic_store_explicit(&trace->lane, lane, memory_order_relaxed);
}

int rtt_probe_mpmc_consumer_done(int consumer, int64_t operations) {
  if (consumer < 1 || consumer > g_probe.mpmc_consumers ||
      operations < 0 || operations > g_probe.mpmc_operations ||
      g_probe.consumer_operations[consumer - 1] != -1) return 0;
  g_probe.consumer_operations[consumer - 1] = operations;
  return 1;
}

void rtt_probe_set_wire_bytes(int64_t payload_wire_bytes_per_op) {
  g_probe.payload_wire_bytes_per_op = payload_wire_bytes_per_op;
}

void rtt_probe_cleanup(void) {
  atomic_store_explicit(&g_probe.active_body, 0, memory_order_relaxed);
  atomic_store_explicit(&g_probe.initialized, 0, memory_order_release);
  free_sample_buf(&g_probe.rtt_samples);
  free_sample_buf(&g_probe.sender_encode_samples);
  free_sample_buf(&g_probe.queue_admission_samples);
  free_sample_buf(&g_probe.wait_registration_samples);
  free_sample_buf(&g_probe.native_wake_samples);
  free_sample_buf(&g_probe.receiver_decode_samples);
  free_sample_buf(&g_probe.reply_processing_samples);
  free_sample_buf(&g_probe.req_one_way_samples);
  free_sample_buf(&g_probe.reply_one_way_samples);
  if (g_probe.op_traces != NULL) {
    raw_free(g_probe.op_traces);
    g_probe.op_traces = NULL;
  }
  g_probe.trace_capacity = 0;
}

void rtt_probe_mark_cold_done(int64_t cold_ns) {
  g_probe.cold_init_ns = cold_ns;
}

void rtt_probe_mark_warmup_done(int64_t warmup_ns, int64_t warmup_ops) {
  g_probe.warmup_ns = warmup_ns;
  g_probe.warmup_ops = warmup_ops;
}

void rtt_probe_mark_setup_start(int64_t lua_bytes) {
  if (g_setup_started) return;
  g_setup_started = 1;
  int64_t handles, waiters;
  live_probe_owners(&g_lua_states_start, &handles, &waiters);
  for (int i = 0; i < 3; i++)
    g_resources_start[i] = atomic_load_explicit(&g_resources[i], memory_order_acquire);
  g_probe.setup_start_lua_bytes = lua_bytes;
  g_probe.setup_start_wall_ns = clock_ns(CLOCK_MONOTONIC);
  take_snapshot(&g_probe.snap_setup_start);
}

void rtt_probe_start_body(int64_t lua_bytes) {
  for (int i = 0; i < 2; i++)
    g_join_suspensions_start[i] = atomic_load_explicit(&g_join_suspensions[i], memory_order_relaxed);
  g_probe.body_start_lua_bytes = lua_bytes;
  take_snapshot(&g_probe.snap_body_start);
  int64_t cur_usable = g_probe.snap_body_start.native_usable_live_bytes;
  atomic_store_explicit(&g_probe.native_usable_peak_bytes, cur_usable, memory_order_relaxed);
  g_probe.body_start_cpu_ns = clock_ns(CLOCK_PROCESS_CPUTIME_ID);
  g_probe.body_start_wall_ns = clock_ns(CLOCK_MONOTONIC);
  atomic_store_explicit(&g_probe.active_body, 1, memory_order_release);
}

void rtt_probe_stop_body(int64_t lua_bytes) {
  atomic_store_explicit(&g_probe.active_body, 0, memory_order_release);
  for (int i = 0; i < 2; i++)
    g_join_suspensions_stop[i] = atomic_load_explicit(&g_join_suspensions[i], memory_order_relaxed);
  g_probe.body_stop_wall_ns = clock_ns(CLOCK_MONOTONIC);
  g_probe.body_stop_cpu_ns = clock_ns(CLOCK_PROCESS_CPUTIME_ID);
  g_probe.body_stop_lua_bytes = lua_bytes;
  take_snapshot(&g_probe.snap_body_stop);
}

void rtt_probe_mark_workers_retired(int64_t lua_bytes) {
  g_probe.workers_retired_wall_ns = clock_ns(CLOCK_MONOTONIC);
  g_probe.workers_retired_lua_bytes = lua_bytes;
  take_snapshot(&g_probe.snap_workers_retired);
}

void rtt_probe_mark_post_gc1(int64_t gc1_ns, int64_t lua_bytes) {
  g_probe.gc1_wall_ns = gc1_ns;
  g_probe.post_gc1_lua_bytes = lua_bytes;
  take_snapshot(&g_probe.snap_post_gc1);
}

void rtt_probe_mark_post_gc2(int64_t gc2_ns, int64_t lua_bytes) {
  g_probe.gc2_wall_ns = gc2_ns;
  g_probe.post_gc2_lua_bytes = lua_bytes;
  take_snapshot(&g_probe.snap_post_gc2);
}

int rtt_probe_op_begin(int op_kind, int endpoint_retains) {
  (void)endpoint_retains; /* Classification never depends on endpoint lock order. */
  if (!atomic_load_explicit(&g_probe.active_body, memory_order_relaxed) ||
      !atomic_load_explicit(&g_probe.instrumented, memory_order_relaxed)) return -1;
  for (int i = 0; i < MAX_ACTIVE_OPS; i++) {
    int expected = 0;
    if (atomic_compare_exchange_strong_explicit(
            &g_active_ops[i].in_use, &expected, 1,
            memory_order_acquire, memory_order_relaxed)) {
      rtt_active_op_t *slot = &g_active_ops[i];
      slot->op_kind = op_kind;
      slot->op_start_ns = clock_ns(CLOCK_MONOTONIC);
      slot->first_attempt_ns = 0;
      slot->dequeue_done_ns = 0;
      slot->slow_check_done_ns = 0;
      tls_current_op_slot = i;
      return i;
    }
  }
  atomic_fetch_add_explicit(&g_probe.slot_exhaustion_failures, 1, memory_order_relaxed);
  return -1;
}

void rtt_probe_op_end(int slot_id, int outcome) {
  if (slot_id < 0 || slot_id >= MAX_ACTIVE_OPS) return;
  rtt_active_op_t *slot = &g_active_ops[slot_id];
  if (tls_current_op_slot == slot_id) tls_current_op_slot = -1;
  if (atomic_load_explicit(&g_probe.active_body, memory_order_relaxed)) {
    if (slot->op_kind == RTT_OP_RECV && outcome == RTT_OUTCOME_OK &&
        slot->dequeue_done_ns > 0)
      push_sample(&g_probe.receiver_decode_samples,
                  clock_ns(CLOCK_MONOTONIC) - slot->dequeue_done_ns);
  }
  atomic_store_explicit(&slot->in_use, 0, memory_order_release);
}

/* Called only at audited branches in a private source copy of titan.thread.
 * An attempt covers mutex acquisition + queue/control branch, not arbitrary
 * locks from endpoint retains, GC, terminal decoding or packet disposal. */
int64_t rtt_probe_attempt_begin(int kind) {
  int64_t now = clock_ns(CLOCK_MONOTONIC);
  int id = tls_current_op_slot;
  if (id >= 0 && id < MAX_ACTIVE_OPS && g_active_ops[id].op_kind == kind &&
      g_active_ops[id].first_attempt_ns == 0) {
    g_active_ops[id].first_attempt_ns = now;
    if (kind == RTT_OP_SEND)
      push_sample(&g_probe.sender_encode_samples, now - g_active_ops[id].op_start_ns);
  }
  return now;
}

void rtt_probe_attempt_end(int kind, void *waiter, int result, int64_t started) {
#if RTT_PROBE_WRAPPERS
  rtt_waiter_entry_t *entry = waiter != NULL ? find_waiter(waiter) : NULL;
  int post_yield = entry != NULL && (entry->cleanup || entry->post_yield);
  /* External registrars execute after yielding: never leave their identity in
   * TLS for a sibling Task's next yield. Legacy ordinary registration is earlier. */
  tls_pending_waiter = result == 1 && !post_yield ? waiter : NULL;
  tls_pending_kind = kind;
  if (post_yield && result == 1) {
    entry->suspended = 1;
    if (atomic_load_explicit(&g_probe.active_body, memory_order_relaxed)) {
      atomic_fetch_add_explicit(&g_probe.actual_suspensions, 1, memory_order_relaxed);
      if (entry->cleanup || kind == RTT_OP_JOIN)
        atomic_fetch_add_explicit(&g_join_suspensions[entry->cleanup ? 1 : 0],
                                  1, memory_order_relaxed);
    }
  }
#endif
  if (started == 0 || !atomic_load_explicit(&g_probe.active_body, memory_order_acquire)) return;
  int64_t now = clock_ns(CLOCK_MONOTONIC);
  if (started >= g_probe.body_start_wall_ns)
    push_sample(&g_probe.queue_admission_samples, now - started);
  if (waiter == NULL && result == 1)
    atomic_fetch_add_explicit(&g_probe.slow_path_attempts, 1, memory_order_relaxed);
  if (waiter != NULL && result == 0)
    atomic_fetch_add_explicit(&g_probe.registration_recheck_successes, 1, memory_order_relaxed);
  int id = tls_current_op_slot;
#if RTT_PROBE_WRAPPERS
  if (entry != NULL && entry->post_yield) id = entry->op_slot;
#endif
  if (id >= 0 && id < MAX_ACTIVE_OPS && g_active_ops[id].op_kind == kind) {
    rtt_active_op_t *slot = &g_active_ops[id];
    if (waiter != NULL && slot->slow_check_done_ns > 0)
      push_sample(&g_probe.wait_registration_samples, now - slot->slow_check_done_ns);
    if (waiter == NULL && result == 1) slot->slow_check_done_ns = now;
    if (kind == RTT_OP_RECV && result == 0) slot->dequeue_done_ns = now;
  }
}

void rtt_probe_join_check(int done) {
  if (atomic_load_explicit(&g_probe.active_body, memory_order_relaxed))
    atomic_fetch_add_explicit(done ? &g_probe.fast_successes : &g_probe.slow_path_attempts,
                              1, memory_order_relaxed);
}

void rtt_probe_fast_success(void) {
  if (atomic_load_explicit(&g_probe.active_body, memory_order_relaxed))
    atomic_fetch_add_explicit(&g_probe.fast_successes, 1, memory_order_relaxed);
}

void rtt_probe_cancelled_wait(void) {
  if (atomic_load_explicit(&g_probe.active_body, memory_order_relaxed))
    atomic_fetch_add_explicit(&g_probe.cancellations, 1, memory_order_relaxed);
}

#if RTT_PROBE_WRAPPERS
static rtt_waiter_entry_t *find_waiter(void *waiter) {
  if (waiter == NULL) return NULL;
  for (int i = 0; i < MAX_ACTIVE_OPS; i++)
    if (atomic_load_explicit(&g_waiters[i].waiter, memory_order_acquire) == waiter)
      return &g_waiters[i];
  return NULL;
}
#endif

void rtt_probe_waiter_bind(void *waiter) {
#if RTT_PROBE_WRAPPERS
  if (find_waiter(waiter) != NULL) return;
  for (int i = 0; i < MAX_ACTIVE_OPS; i++) {
    void *expected = NULL;
    if (atomic_compare_exchange_strong_explicit(&g_waiters[i].waiter, &expected, waiter,
          memory_order_acquire, memory_order_relaxed)) {
      atomic_store_explicit(&g_waiters[i].notified_ns, 0, memory_order_relaxed);
      atomic_store_explicit(&g_waiters[i].notifications, 0, memory_order_relaxed);
      g_waiters[i].cleanup = 0;
      g_waiters[i].post_yield = 0;
      g_waiters[i].suspended = 0;
      g_waiters[i].op_slot = tls_current_op_slot;
      g_waiters[i].target = NULL;
      return;
    }
  }
  atomic_fetch_add_explicit(&g_probe.slot_exhaustion_failures, 1, memory_order_relaxed);
#else
  (void)waiter;
#endif
}

void rtt_probe_external_prepare(void *waiter) {
  rtt_probe_waiter_bind(waiter);
#if RTT_PROBE_WRAPPERS
  rtt_waiter_entry_t *entry = find_waiter(waiter);
  if (entry != NULL) {
    entry->post_yield = 1;
    entry->op_slot = tls_current_op_slot;
  }
#endif
}

void rtt_probe_retirement_bind(void *context, void *target) {
  rtt_probe_waiter_bind(context);
#if RTT_PROBE_WRAPPERS
  rtt_waiter_entry_t *entry = find_waiter(context);
  if (entry != NULL) {
    entry->cleanup = 1;
    entry->post_yield = 1;
    entry->op_slot = -1;
    entry->target = target;
  }
#else
  (void)target;
#endif
}

void rtt_probe_retirement_notify(void *context, void *target) {
#if RTT_PROBE_WRAPPERS
  rtt_waiter_entry_t *entry = find_waiter(context);
  if (entry == NULL || entry->target != target) {
    atomic_fetch_add_explicit(&g_probe.slot_exhaustion_failures, 1, memory_order_relaxed);
    return;
  }
  rtt_probe_waiter_notify(context);
#else
  (void)context; (void)target;
#endif
}

void rtt_probe_retirement_check(void *context, int status) {
#if RTT_PROBE_WRAPPERS
  if (find_waiter(context) != NULL) rtt_probe_join_check(status == 0);
#else
  (void)context; (void)status;
#endif
}

void rtt_probe_retirement_registered(void *context, int pending) {
#if RTT_PROBE_WRAPPERS
  rtt_waiter_entry_t *entry = find_waiter(context);
  if (entry == NULL || entry->suspended) return;
  if (pending) entry->suspended = 1;
  if (atomic_load_explicit(&g_probe.active_body, memory_order_relaxed)) {
    if (pending) {
      atomic_fetch_add_explicit(&g_probe.actual_suspensions, 1, memory_order_relaxed);
      atomic_fetch_add_explicit(&g_join_suspensions[1], 1, memory_order_relaxed);
    } else {
      atomic_fetch_add_explicit(&g_probe.registration_recheck_successes, 1,
                                memory_order_relaxed);
    }
  }
#else
  (void)context; (void)pending;
#endif
}

void rtt_probe_cleanup_prepare(void *waiter) {
  rtt_probe_waiter_bind(waiter);
#if RTT_PROBE_WRAPPERS
  rtt_waiter_entry_t *entry = find_waiter(waiter);
  if (entry != NULL) entry->cleanup = 1;
#endif
}

void rtt_probe_waiter_complete(void *waiter, int normal) {
#if RTT_PROBE_WRAPPERS
  if (tls_pending_waiter == waiter) tls_pending_waiter = NULL;
  rtt_waiter_entry_t *entry = find_waiter(waiter);
  if (entry == NULL) return;
  if (atomic_load_explicit(&g_probe.active_body, memory_order_relaxed)) {
    unsigned signals = atomic_load_explicit(&entry->notifications, memory_order_acquire);
    int64_t notified = atomic_load_explicit(&entry->notified_ns, memory_order_relaxed);
    int64_t returned = normal && entry->suspended && signals == 1 && notified > 0
                           ? clock_ns(CLOCK_MONOTONIC) : 0;
    if (normal && entry->suspended && signals == 1 && notified > 0 && returned >= notified) {
      push_sample(&g_probe.native_wake_samples, returned - notified);
      atomic_fetch_add_explicit(&g_probe.attributed_wakes, 1, memory_order_relaxed);
    } else if (signals != 0 || !normal) {
      atomic_fetch_add_explicit(&g_probe.unattributed_wakes, 1, memory_order_relaxed);
    }
  }
  atomic_store_explicit(&entry->waiter, NULL, memory_order_release);
#else
  (void)waiter;
  (void)normal;
#endif
}

void rtt_probe_waiter_signal_result(void *waiter, int result) {
#if RTT_PROBE_WRAPPERS
  rtt_waiter_entry_t *entry = find_waiter(waiter);
  if (entry != NULL && result != 0)
    atomic_store_explicit(&entry->notifications, UINT32_MAX, memory_order_release);
#else
  (void)waiter;
  (void)result;
#endif
}

void rtt_probe_waiter_notify(void *waiter) {
#if RTT_PROBE_WRAPPERS
  if (atomic_load_explicit(&g_probe.active_body, memory_order_relaxed))
    atomic_fetch_add_explicit(&g_probe.notifications, 1, memory_order_relaxed);
  for (int i = 0; i < MAX_ACTIVE_OPS; i++) {
    if (atomic_load_explicit(&g_waiters[i].waiter, memory_order_acquire) == waiter) {
      atomic_store_explicit(&g_waiters[i].notified_ns, clock_ns(CLOCK_MONOTONIC), memory_order_relaxed);
      atomic_fetch_add_explicit(&g_waiters[i].notifications, 1, memory_order_release);
      return;
    }
  }
#else
  (void)waiter;
#endif
}

void rtt_probe_record_sample(int64_t elapsed_ns) {
  if (!atomic_load_explicit(&g_probe.active_body, memory_order_relaxed)) return;
  push_sample(&g_probe.rtt_samples, elapsed_ns);
}

void rtt_probe_trace_client_send_start(int64_t req_id, int64_t t_ns) {
  if (req_id <= 0 || (size_t)req_id > g_probe.trace_capacity || g_probe.op_traces == NULL) return;
  atomic_store_explicit(&g_probe.op_traces[req_id].t0_send_start, t_ns, memory_order_relaxed);
}

void rtt_probe_trace_client_send_done(int64_t req_id, int64_t t_ns) {
  if (!atomic_load_explicit(&g_probe.instrumented, memory_order_relaxed)) return;
  if (req_id <= 0 || (size_t)req_id > g_probe.trace_capacity || g_probe.op_traces == NULL) return;
  atomic_store_explicit(&g_probe.op_traces[req_id].t1_send_done, t_ns, memory_order_relaxed);
}

void rtt_probe_trace_worker_recv(int64_t req_id) {
  if (!atomic_load_explicit(&g_probe.instrumented, memory_order_relaxed)) return;
  if (req_id <= 0 || (size_t)req_id > g_probe.trace_capacity || g_probe.op_traces == NULL) return;
  int64_t now = clock_ns(CLOCK_MONOTONIC);
  atomic_store_explicit(&g_probe.op_traces[req_id].t2_worker_recv, now, memory_order_relaxed);
}

void rtt_probe_trace_worker_reply_start(int64_t req_id) {
  if (!atomic_load_explicit(&g_probe.instrumented, memory_order_relaxed)) return;
  if (req_id <= 0 || (size_t)req_id > g_probe.trace_capacity || g_probe.op_traces == NULL) return;
  int64_t now = clock_ns(CLOCK_MONOTONIC);
  atomic_store_explicit(&g_probe.op_traces[req_id].t3_reply_start, now, memory_order_relaxed);
}

void rtt_probe_trace_worker_reply_done(int64_t req_id) {
  if (!atomic_load_explicit(&g_probe.instrumented, memory_order_relaxed)) return;
  if (req_id <= 0 || (size_t)req_id > g_probe.trace_capacity || g_probe.op_traces == NULL) return;
  int64_t now = clock_ns(CLOCK_MONOTONIC);
  atomic_store_explicit(&g_probe.op_traces[req_id].t4_reply_done, now, memory_order_release);
}

void rtt_probe_trace_client_reply_done(int64_t req_id, int64_t t_ns) {
  if (req_id <= 0 || (size_t)req_id > g_probe.trace_capacity || g_probe.op_traces == NULL) return;
  rtt_op_trace_t *tr = &g_probe.op_traces[req_id];
  atomic_store_explicit(&tr->t5_reply_recv, t_ns, memory_order_relaxed);
  if (!atomic_load_explicit(&g_probe.instrumented, memory_order_relaxed)) return;
  int64_t t0 = atomic_load_explicit(&tr->t0_send_start, memory_order_relaxed);
  int64_t t2 = atomic_load_explicit(&tr->t2_worker_recv, memory_order_acquire);
  int64_t t3 = atomic_load_explicit(&tr->t3_reply_start, memory_order_relaxed);
  if (t2 >= t0 && t0 > 0) {
    push_sample(&g_probe.req_one_way_samples, t2 - t0);
  }
  if (t3 >= t2 && t2 > 0) {
    push_sample(&g_probe.reply_processing_samples, t3 - t2);
  }
  if (t_ns >= t3 && t3 > 0) {
    push_sample(&g_probe.reply_one_way_samples, t_ns - t3);
  }
}


#if RTT_PROBE_WRAPPERS
static void *rtt_lua_alloc(void *ud, void *ptr, size_t osize, size_t nsize) {
  rtt_lua_state_slot_t *slot = (rtt_lua_state_slot_t *)ud;
  int track = 1; /* Include the very first allocation and final lua_close free. */
  tls_in_lua_alloc++;
  void *res = slot->orig_alloc(slot->orig_ud, ptr, osize, nsize);
  tls_in_lua_alloc--;

  if (track) {
    if (nsize == 0) {
      if (ptr != NULL) {
        atomic_fetch_add_explicit(&g_probe.lua_free_calls, 1, memory_order_relaxed);
        atomic_fetch_sub_explicit(&g_probe.lua_live_delta_bytes, (int64_t)osize, memory_order_relaxed);
      }
    } else if (res != NULL) {
      atomic_fetch_add_explicit(&g_probe.lua_requested_bytes, (uint64_t)nsize, memory_order_relaxed);
      if (ptr == NULL) {
        /* When ptr == NULL, osize encodes the Lua object type tag, not a prior block size. */
        atomic_fetch_add_explicit(&g_probe.lua_alloc_calls, 1, memory_order_relaxed);
        atomic_fetch_add_explicit(&g_probe.lua_live_delta_bytes, (int64_t)nsize, memory_order_relaxed);
      } else {
        atomic_fetch_add_explicit(&g_probe.lua_realloc_calls, 1, memory_order_relaxed);
        atomic_fetch_add_explicit(&g_probe.lua_live_delta_bytes,
                                  (int64_t)nsize - (int64_t)osize, memory_order_relaxed);
      }
    }
  }
  return res;
}

lua_State *__wrap_lua_newstate(lua_Alloc f, void *ud, unsigned int seed) {
  if (f == rtt_lua_alloc) {
    rtt_lua_state_slot_t *parent = (rtt_lua_state_slot_t *)ud;
    f = parent->orig_alloc;
    ud = parent->orig_ud;
  }
  if (f == NULL) return __real_lua_newstate(f, ud, seed);
  for (size_t i = 0; i < MAX_LUA_STATES; i++) {
    int expected = 0;
    if (atomic_compare_exchange_strong_explicit(
            &g_lua_slots[i].in_use, &expected, 1,
            memory_order_acquire, memory_order_relaxed)) {
      g_lua_slots[i].orig_alloc = f;
      g_lua_slots[i].orig_ud = ud;
      atomic_store_explicit(&g_lua_slots[i].state, NULL, memory_order_relaxed);
      lua_State *L = __real_lua_newstate(rtt_lua_alloc, &g_lua_slots[i], seed);
      if (L == NULL) {
        atomic_store_explicit(&g_lua_slots[i].in_use, 0, memory_order_release);
        return NULL;
      }
      atomic_store_explicit(&g_lua_slots[i].state, L, memory_order_release);
      return L;
    }
  }
  /* Never modulo-overwrite an active allocator slot; record exhaustion and reject. */
  atomic_fetch_add_explicit(&g_probe.slot_exhaustion_failures, 1, memory_order_relaxed);
  return NULL;
}

void __wrap_lua_close(lua_State *L) {
  if (L == NULL) return;
  /* Find by the birth state, not lua_getallocf on a possibly replaced allocator. */
  rtt_lua_state_slot_t *slot = NULL;
  for (size_t i = 0; i < MAX_LUA_STATES; i++)
    if (atomic_load_explicit(&g_lua_slots[i].state, memory_order_acquire) == L) {
      slot = &g_lua_slots[i];
      break;
    }
  __real_lua_close(L);
  if (slot != NULL) {
    atomic_store_explicit(&slot->state, NULL, memory_order_relaxed);
    atomic_store_explicit(&slot->in_use, 0, memory_order_release);
  }
}

void *__wrap_malloc(size_t size) {
  void *ptr = __real_malloc(size);
  if (tls_in_lua_alloc == 0) {
    if (ptr != NULL) {
      size_t usable = block_usable_size(ptr);
      atomic_fetch_add_explicit(&g_probe.native_malloc_calls, 1, memory_order_relaxed);
      atomic_fetch_add_explicit(&g_probe.native_requested_bytes, (uint64_t)size, memory_order_relaxed);
      atomic_fetch_add_explicit(&g_probe.native_live_blocks, 1, memory_order_relaxed);
      int64_t cur = atomic_fetch_add_explicit(
          &g_probe.native_usable_live_bytes, (int64_t)usable, memory_order_relaxed) + (int64_t)usable;
      if (atomic_load_explicit(&g_probe.active_body, memory_order_relaxed)) {
        update_peak_usable(cur);
      }
    }
  }
  return ptr;
}

void *__wrap_calloc(size_t nmemb, size_t size) {
  void *ptr = __real_calloc(nmemb, size);
  if (tls_in_lua_alloc == 0) {
    if (ptr != NULL) {
      size_t usable = block_usable_size(ptr);
      atomic_fetch_add_explicit(&g_probe.native_calloc_calls, 1, memory_order_relaxed);
      atomic_fetch_add_explicit(&g_probe.native_requested_bytes,
                                (uint64_t)(nmemb * size), memory_order_relaxed);
      atomic_fetch_add_explicit(&g_probe.native_live_blocks, 1, memory_order_relaxed);
      int64_t cur = atomic_fetch_add_explicit(
          &g_probe.native_usable_live_bytes, (int64_t)usable, memory_order_relaxed) + (int64_t)usable;
      if (atomic_load_explicit(&g_probe.active_body, memory_order_relaxed)) {
        update_peak_usable(cur);
      }
    }
  }
  return ptr;
}

void *__wrap_realloc(void *ptr, size_t size) {
  int track = tls_in_lua_alloc == 0;
  size_t old_usable = (track && ptr != NULL) ? block_usable_size(ptr) : 0;
  void *res = __real_realloc(ptr, size);
  if (track) {
    if (size == 0) {
      if (ptr != NULL) {
        atomic_fetch_add_explicit(&g_probe.native_free_calls, 1, memory_order_relaxed);
        atomic_fetch_sub_explicit(&g_probe.native_live_blocks, 1, memory_order_relaxed);
        atomic_fetch_sub_explicit(&g_probe.native_usable_live_bytes, (int64_t)old_usable, memory_order_relaxed);
      }
    } else if (res != NULL) {
      size_t new_usable = block_usable_size(res);
      atomic_fetch_add_explicit(&g_probe.native_requested_bytes, (uint64_t)size, memory_order_relaxed);
      if (ptr == NULL) {
        atomic_fetch_add_explicit(&g_probe.native_malloc_calls, 1, memory_order_relaxed);
        atomic_fetch_add_explicit(&g_probe.native_live_blocks, 1, memory_order_relaxed);
      } else {
        atomic_fetch_add_explicit(&g_probe.native_realloc_calls, 1, memory_order_relaxed);
      }
      int64_t delta = (int64_t)new_usable - (int64_t)old_usable;
      int64_t cur = atomic_fetch_add_explicit(
          &g_probe.native_usable_live_bytes, delta, memory_order_relaxed) + delta;
      if (atomic_load_explicit(&g_probe.active_body, memory_order_relaxed)) {
        update_peak_usable(cur);
      }
    }
  }
  return res;
}

void __wrap_free(void *ptr) {
  if (ptr != NULL && tls_in_lua_alloc == 0) {
    size_t usable = block_usable_size(ptr);
    atomic_fetch_add_explicit(&g_probe.native_free_calls, 1, memory_order_relaxed);
    atomic_fetch_sub_explicit(&g_probe.native_live_blocks, 1, memory_order_relaxed);
    atomic_fetch_sub_explicit(&g_probe.native_usable_live_bytes, (int64_t)usable, memory_order_relaxed);
  }
  __real_free(ptr);
}

void *__wrap_memcpy(void *dst, const void *src, size_t n) {
  if (n > 0 && atomic_load_explicit(&g_probe.active_body, memory_order_relaxed)) {
    if (tls_in_lua_alloc > 0) {
      atomic_fetch_add_explicit(&g_probe.inside_lua_alloc_memcpy_calls, 1, memory_order_relaxed);
      atomic_fetch_add_explicit(&g_probe.inside_lua_alloc_memcpy_bytes, (uint64_t)n, memory_order_relaxed);
    } else {
      atomic_fetch_add_explicit(&g_probe.outside_lua_alloc_memcpy_calls, 1, memory_order_relaxed);
      atomic_fetch_add_explicit(&g_probe.outside_lua_alloc_memcpy_bytes, (uint64_t)n, memory_order_relaxed);
    }
  }
  return __real_memcpy(dst, src, n);
}

void *__wrap_memmove(void *dst, const void *src, size_t n) {
  if (n > 0 && atomic_load_explicit(&g_probe.active_body, memory_order_relaxed)) {
    if (tls_in_lua_alloc > 0) {
      atomic_fetch_add_explicit(&g_probe.inside_lua_alloc_memcpy_calls, 1, memory_order_relaxed);
      atomic_fetch_add_explicit(&g_probe.inside_lua_alloc_memcpy_bytes, (uint64_t)n, memory_order_relaxed);
    } else {
      atomic_fetch_add_explicit(&g_probe.outside_lua_alloc_memcpy_calls, 1, memory_order_relaxed);
      atomic_fetch_add_explicit(&g_probe.outside_lua_alloc_memcpy_bytes, (uint64_t)n, memory_order_relaxed);
    }
  }
  return __real_memmove(dst, src, n);
}

int __wrap_uv_async_init(uv_loop_t *loop, uv_async_t *async, uv_async_cb async_cb) {
  int rc = __real_uv_async_init(loop, async, async_cb);
  if (rc != 0) return rc;
  atomic_fetch_add_explicit(&g_probe.uv_async_init_calls, 1, memory_order_relaxed);
  rtt_async_handles_lock();
  size_t slot = 0;
  while (slot < g_async_handles_used && g_async_handles[slot].handle != NULL) slot++;
  if (slot < MAX_ASYNC_HANDLES) {
    if (slot == g_async_handles_used) g_async_handles_used++;
    g_async_handles[slot].loop = loop;
    g_async_handles[slot].close_cb = NULL;
    g_async_handles[slot].handle = (uv_handle_t *)async;
    rtt_async_handles_unlock();
    return rc;
  }
  rtt_async_handles_unlock();
  atomic_fetch_add_explicit(&g_probe.slot_exhaustion_failures, 1, memory_order_relaxed);
  return rc; /* Never alter an accepted native operation; campaign rejects exhaustion. */
}

int __wrap_uv_async_send(uv_async_t *async) {
  atomic_fetch_add_explicit(&g_probe.uv_async_send_calls, 1, memory_order_relaxed);
  return __real_uv_async_send(async);
}

static void rtt_async_closed(uv_handle_t *handle) {
  uv_close_cb callback = NULL;
  int found = 0;
  rtt_async_handles_lock();
  for (size_t i = 0; i < g_async_handles_used; i++) {
    if (g_async_handles[i].handle == handle) {
      callback = g_async_handles[i].close_cb;
      g_async_handles[i].handle = NULL;
      g_async_handles[i].loop = NULL;
      g_async_handles[i].close_cb = NULL;
      found = 1;
      break;
    }
  }
  rtt_async_handles_unlock();
  if (found) {
    atomic_fetch_add_explicit(&g_probe.uv_async_close_callbacks, 1, memory_order_relaxed);
    if (callback != NULL) callback(handle);
  } else {
    atomic_fetch_add_explicit(&g_probe.slot_exhaustion_failures, 1, memory_order_relaxed);
  }
}

void __wrap_uv_close(uv_handle_t *handle, uv_close_cb close_cb) {
  atomic_fetch_add_explicit(&g_probe.uv_close_total_calls, 1, memory_order_relaxed);
  int found = 0;
  rtt_async_handles_lock();
  for (size_t i = 0; i < g_async_handles_used; i++) {
    if (g_async_handles[i].handle == handle) {
      g_async_handles[i].close_cb = close_cb;
      found = 1;
      break;
    }
  }
  rtt_async_handles_unlock();
  if (found) {
    atomic_fetch_add_explicit(&g_probe.uv_async_close_calls, 1, memory_order_relaxed);
    __real_uv_close(handle, rtt_async_closed);
  } else {
    __real_uv_close(handle, close_cb);
  }
}

int __wrap_uv_loop_close(uv_loop_t *loop) {
  atomic_fetch_add_explicit(&g_probe.uv_loop_close_calls, 1, memory_order_relaxed);
  int rc = __real_uv_loop_close(loop);
  if (rc != 0) return rc;
  atomic_fetch_add_explicit(&g_probe.uv_loop_close_successes, 1, memory_order_relaxed);

  /* Libuv initializes its internal work-queue async through uv_async_init,
   * but destroys it directly during successful loop close, without uv_close.
   * Success proves every remaining handle owned by this loop is retired.
   * Busy/failed loop closes above never discharge any tracked handle. */
  uint64_t retired = 0;
  rtt_async_handles_lock();
  for (size_t i = 0; i < g_async_handles_used; i++) {
    if (g_async_handles[i].handle != NULL && g_async_handles[i].loop == loop) {
      g_async_handles[i].handle = NULL;
      g_async_handles[i].loop = NULL;
      g_async_handles[i].close_cb = NULL;
      retired++;
    }
  }
  rtt_async_handles_unlock();
  atomic_fetch_add_explicit(&g_probe.uv_async_loop_retirements, retired, memory_order_relaxed);
  return rc;
}

mco_result __wrap_mco_yield(mco_coro *co, void *tag) {
  int saved_slot = tls_current_op_slot;
  void *waiter = tls_pending_waiter;
  int kind = tls_pending_kind;
  tls_current_op_slot = -1;
  tls_pending_waiter = NULL;
  rtt_waiter_entry_t *entry = waiter != NULL ? find_waiter(waiter) : NULL;
  if (entry != NULL) entry->suspended = 1;
  if (waiter != NULL && atomic_load_explicit(&g_probe.active_body, memory_order_relaxed)) {
    atomic_fetch_add_explicit(&g_probe.actual_suspensions, 1, memory_order_relaxed);
    if (kind == RTT_OP_JOIN)
      atomic_fetch_add_explicit(&g_join_suspensions[0], 1, memory_order_relaxed);
  }
  mco_result result = __real_mco_yield(co, tag);
  tls_current_op_slot = saved_slot;
  return result;
}
#endif

static int cmp_u64(const void *a, const void *b) {
  uint64_t x = *(const uint64_t *)a;
  uint64_t y = *(const uint64_t *)b;
  return (x > y) - (x < y);
}

static void write_dist_json(FILE *out, const char *name, rtt_sample_buf_t *buf, int trailing_comma) {
  size_t total = atomic_load_explicit(&buf->count, memory_order_relaxed);
  size_t trunc = atomic_load_explicit(&buf->truncated, memory_order_relaxed);
  size_t n = total < buf->capacity ? total : buf->capacity;
  uint64_t min_v = 0, p50_v = 0, p95_v = 0, p99_v = 0, max_v = 0;
  double mean_v = 0.0;
  if (n > 0 && buf->values != NULL) {
    uint64_t *sorted = buf->values;
    qsort(sorted, n, sizeof(uint64_t), cmp_u64);
    min_v = sorted[0];
    p50_v = sorted[(n - 1) * 50 / 100];
    p95_v = sorted[(n - 1) * 95 / 100];
    p99_v = sorted[(n - 1) * 99 / 100];
    max_v = sorted[n - 1];
    double sum = 0.0;
    for (size_t i = 0; i < n; i++) sum += (double)sorted[i];
    mean_v = sum / (double)n;
  }
  fprintf(out,
          "    \"%s\": {\"samples\": %zu, \"truncated\": %zu, \"min_ns\": %llu, "
          "\"p50_ns\": %llu, \"p95_ns\": %llu, \"p99_ns\": %llu, \"max_ns\": %llu, \"mean_ns\": %.2f}%s\n",
          name, n, trunc,
          (unsigned long long)min_v, (unsigned long long)p50_v,
          (unsigned long long)p95_v, (unsigned long long)p99_v,
          (unsigned long long)max_v, mean_v,
          trailing_comma ? "," : "");
}

static int write_mpmc_trace(const char *path, int64_t operations,
                            int64_t producers, int64_t lanes, int64_t consumers) {
  if (operations != g_probe.mpmc_operations || producers != g_probe.mpmc_producers ||
      lanes != g_probe.mpmc_lanes || consumers != g_probe.mpmc_consumers ||
      atomic_load_explicit(&g_probe.mpmc_trace_failures, memory_order_relaxed) != 0 ||
      path == NULL || path[0] == '\0') return 0;
  int64_t completed = 0;
  for (int i = 0; i < g_probe.mpmc_consumers; i++) {
    if (g_probe.consumer_operations[i] < 0) return 0;
    completed += g_probe.consumer_operations[i];
  }
  if (completed != operations) return 0;
  FILE *out = fopen(path, "w");
  if (out == NULL) return 0;
  fprintf(out, "request_id\tproducer\tlane\tpermit_start_ns\tsend_start_ns\treply_received_ns\n");
  int invalid = 0;
  for (int64_t id = 1; id <= operations; id++) {
    rtt_op_trace_t *trace = &g_probe.op_traces[id];
    int producer = atomic_load_explicit(&trace->producer, memory_order_relaxed);
    int lane = atomic_load_explicit(&trace->lane, memory_order_relaxed);
    int64_t permit = atomic_load_explicit(&trace->permit_start, memory_order_relaxed);
    int64_t send = atomic_load_explicit(&trace->t0_send_start, memory_order_relaxed);
    int64_t reply = atomic_load_explicit(&trace->t5_reply_recv, memory_order_relaxed);
    if (producer != (id - 1) % producers + 1 ||
        lane != ((id - 1) / producers) % lanes + 1 ||
        permit < g_probe.body_start_wall_ns || send < permit || reply < send ||
        reply > g_probe.body_stop_wall_ns) {
      invalid = 1;
      break;
    }
    fprintf(out, "%lld\t%d\t%d\t%lld\t%lld\t%lld\n", (long long)id, producer, lane,
            (long long)(permit - g_probe.body_start_wall_ns),
            (long long)(send - g_probe.body_start_wall_ns),
            (long long)(reply - g_probe.body_start_wall_ns));
  }
  int failed = ferror(out);
  if (fclose(out) != 0 || failed || invalid) return 0;
  return 1;
}

int rtt_probe_finish_json(const char *case_name, const char *category,
                          const char *protocol, int64_t operations,
                          int64_t in_flight, int64_t producers,
                          int64_t consumers, int64_t capacity,
                          int64_t checksum, const char *raw_samples_path,
                          const char *request_trace_path) {
  if (g_probe.mpmc_operations != 0 &&
      !write_mpmc_trace(request_trace_path, operations, producers, in_flight, consumers)) return 0;
  if (raw_samples_path != NULL && raw_samples_path[0] != '\0') {
    FILE *f = fopen(raw_samples_path, "w");
    if (f == NULL) return 0;
    fprintf(f, "index\trtt_ns\n");
    size_t total = atomic_load_explicit(&g_probe.rtt_samples.count, memory_order_relaxed);
    size_t n = total < g_probe.rtt_samples.capacity ? total : g_probe.rtt_samples.capacity;
    for (size_t i = 0; i < n; i++) {
      fprintf(f, "%zu\t%llu\n", i + 1, (unsigned long long)g_probe.rtt_samples.values[i]);
    }
    int failed = ferror(f);
    if (fclose(f) != 0 || failed) return 0;
  }

  struct rusage ru;
  long peak_rss_kib = 0;
  if (getrusage(RUSAGE_SELF, &ru) == 0) {
#if defined(__APPLE__)
    peak_rss_kib = ru.ru_maxrss / 1024;
#else
    peak_rss_kib = ru.ru_maxrss;
#endif
  }

  int64_t setup_wall_ns = g_probe.body_start_wall_ns - g_probe.setup_start_wall_ns;
  if (setup_wall_ns < 0) setup_wall_ns = 0;
  int64_t body_wall_ns = g_probe.body_stop_wall_ns - g_probe.body_start_wall_ns;
  if (body_wall_ns < 0) body_wall_ns = 0;
  int64_t body_cpu_ns = g_probe.body_stop_cpu_ns - g_probe.body_start_cpu_ns;
  if (body_cpu_ns < 0) body_cpu_ns = 0;
  int64_t retire_wall_ns = g_probe.workers_retired_wall_ns - g_probe.body_stop_wall_ns;
  if (retire_wall_ns < 0) retire_wall_ns = 0;

  double ns_per_op = operations > 0 ? (double)body_wall_ns / (double)operations : 0.0;
  double throughput = body_wall_ns > 0
      ? ((double)operations * 1e9) / (double)body_wall_ns
      : 0.0;

  const rtt_counters_snapshot_t *b0 = &g_probe.snap_body_start;
  const rtt_counters_snapshot_t *b1 = &g_probe.snap_body_stop;
  const rtt_counters_snapshot_t *s0 = &g_probe.snap_setup_start;
  const rtt_counters_snapshot_t *g2 = &g_probe.snap_post_gc2;

  int inst = atomic_load_explicit(&g_probe.instrumented, memory_order_relaxed);
  uint64_t attr_wakes = b1->attributed_wakes - b0->attributed_wakes;
  uint64_t unattr_wakes = b1->unattributed_wakes - b0->unattributed_wakes;
  const char *wake_mode = "not_instrumented";
  if (inst) {
    if (attr_wakes > 0 && unattr_wakes == 0) {
      wake_mode = "exact_waiter_notification_to_continuation";
    } else if (attr_wakes > 0 && unattr_wakes > 0) {
      wake_mode = "partial_exact_only";
    } else if (unattr_wakes > 0) {
      wake_mode = "unavailable_unawaited_cancelled_failed_or_nonunique_notification";
    } else {
      wake_mode = "no_suspensions";
    }
  }

  fprintf(stdout, "{\n");
  fprintf(stdout, "  \"case\": \"%s\",\n", case_name ? case_name : "");
  fprintf(stdout, "  \"category\": \"%s\",\n", category ? category : "");
  fprintf(stdout, "  \"protocol\": \"%s\",\n", protocol ? protocol : "");
  fprintf(stdout, "  \"operations\": %lld,\n", (long long)operations);
  fprintf(stdout, "  \"in_flight\": %lld,\n", (long long)in_flight);
  fprintf(stdout, "  \"producers\": %lld,\n", (long long)producers);
  fprintf(stdout, "  \"consumers\": %lld,\n", (long long)consumers);
  fprintf(stdout, "  \"capacity\": %lld,\n", (long long)capacity);
  fprintf(stdout, "  \"checksum\": %lld,\n", (long long)checksum);
  fprintf(stdout, "  \"instrumented\": %s,\n", inst ? "true" : "false");
  fprintf(stdout, "  \"wrapper_hooks_compiled\": %s,\n", RTT_PROBE_WRAPPERS ? "true" : "false");
  fprintf(stdout, "  \"native_wake_attribution_mode\": \"%s\",\n", wake_mode);
  fprintf(stdout, "  \"measurement_scope\": \"native branch events occurring inside body; stage intervals overlap\",\n");
  if (g_probe.mpmc_operations != 0) {
    fprintf(stdout, "  \"fairness\": {\"request_samples\": %lld, \"consumer_operations\": [",
            (long long)g_probe.mpmc_operations);
    for (int i = 0; i < g_probe.mpmc_consumers; i++)
      fprintf(stdout, "%s%lld", i == 0 ? "" : ",", (long long)g_probe.consumer_operations[i]);
    fprintf(stdout, "]},\n");
  } else {
    fprintf(stdout, "  \"fairness\": null,\n");
  }
  int64_t states, handles, waiters;
  live_probe_owners(&states, &handles, &waiters);
  fprintf(stdout, "  \"lifecycle\": {\"channels_delta\": %lld, \"controls_delta\": %lld, "
                  "\"active_workers\": %lld, \"lua_states_delta\": %lld, "
                  "\"active_async_handles\": %lld, \"pending_waiter_probes\": %lld},\n",
          (long long)(atomic_load_explicit(&g_resources[0], memory_order_acquire) - g_resources_start[0]),
          (long long)(atomic_load_explicit(&g_resources[1], memory_order_acquire) - g_resources_start[1]),
          (long long)atomic_load_explicit(&g_resources[2], memory_order_acquire),
          (long long)(states - g_lua_states_start), (long long)handles, (long long)waiters);

  fprintf(stdout, "  \"calibration\": {\n");
  fprintf(stdout, "    \"ran\": %s,\n", g_probe.calibration_ran ? "true" : "false");
  fprintf(stdout, "    \"passed\": %s,\n", g_probe.calibration_passed ? "true" : "false");
  fprintf(stdout, "    \"lua_birth_allocs\": %lld,\n", (long long)g_probe.cal_lua_birth_allocs);
  fprintf(stdout, "    \"lua_birth_native_leak_allocs\": %lld,\n",
          (long long)g_probe.cal_lua_birth_native_leak_allocs);
  fprintf(stdout, "    \"lua_post_close_delta_bytes\": %lld,\n",
          (long long)g_probe.cal_lua_post_close_delta_bytes);
  fprintf(stdout, "    \"native_cycle_blocks_delta\": %lld,\n",
          (long long)g_probe.cal_native_cycle_blocks_delta);
  fprintf(stdout, "    \"native_cycle_usable_delta\": %lld,\n",
          (long long)g_probe.cal_native_cycle_usable_delta);
  fprintf(stdout, "    \"slot_exhaustion_failures\": %llu\n",
          (unsigned long long)atomic_load_explicit(&g_probe.slot_exhaustion_failures, memory_order_relaxed));
  fprintf(stdout, "  },\n");

  fprintf(stdout, "  \"clocks\": {\n");
  fprintf(stdout, "    \"cold_init_ns\": %lld,\n", (long long)g_probe.cold_init_ns);
  fprintf(stdout, "    \"warmup_ns\": %lld,\n", (long long)g_probe.warmup_ns);
  fprintf(stdout, "    \"warmup_ops\": %lld,\n", (long long)g_probe.warmup_ops);
  fprintf(stdout, "    \"setup_wall_ns\": %lld,\n", (long long)setup_wall_ns);
  fprintf(stdout, "    \"body_wall_ns\": %lld,\n", (long long)body_wall_ns);
  fprintf(stdout, "    \"body_cpu_ns\": %lld,\n", (long long)body_cpu_ns);
  fprintf(stdout, "    \"retire_wall_ns\": %lld,\n", (long long)retire_wall_ns);
  fprintf(stdout, "    \"gc1_wall_ns\": %lld,\n", (long long)g_probe.gc1_wall_ns);
  fprintf(stdout, "    \"gc2_wall_ns\": %lld,\n", (long long)g_probe.gc2_wall_ns);
  fprintf(stdout, "    \"ns_per_op\": %.4f,\n", ns_per_op);
  fprintf(stdout, "    \"us_per_op\": %.6f,\n", ns_per_op / 1000.0);
  fprintf(stdout, "    \"throughput_ops_per_sec\": %.2f\n", throughput);
  fprintf(stdout, "  },\n");

  fprintf(stdout, "  \"distributions\": {\n");
  write_dist_json(stdout, "rtt", &g_probe.rtt_samples, 1);
  write_dist_json(stdout, "sender_encode", &g_probe.sender_encode_samples, 1);
  write_dist_json(stdout, "queue_admission", &g_probe.queue_admission_samples, 1);
  write_dist_json(stdout, "wait_registration", &g_probe.wait_registration_samples, 1);
  write_dist_json(stdout, "native_wake", &g_probe.native_wake_samples, 1);
  write_dist_json(stdout, "receiver_decode", &g_probe.receiver_decode_samples, 1);
  write_dist_json(stdout, "reply_processing", &g_probe.reply_processing_samples, 1);
  write_dist_json(stdout, "req_one_way", &g_probe.req_one_way_samples, 1);
  write_dist_json(stdout, "reply_one_way", &g_probe.reply_one_way_samples, 0);
  fprintf(stdout, "  },\n");

  fprintf(stdout, "  \"wait_counters\": {\n");
  fprintf(stdout, "    \"ordinary_join_suspensions\": %llu,\n",
          (unsigned long long)(g_join_suspensions_stop[0] - g_join_suspensions_start[0]));
  fprintf(stdout, "    \"cleanup_join_suspensions\": %llu,\n",
          (unsigned long long)(g_join_suspensions_stop[1] - g_join_suspensions_start[1]));
  fprintf(stdout, "    \"fast_successes\": %llu,\n",
          (unsigned long long)(b1->fast_successes - b0->fast_successes));
  fprintf(stdout, "    \"slow_path_attempts\": %llu,\n",
          (unsigned long long)(b1->slow_path_attempts - b0->slow_path_attempts));
  fprintf(stdout, "    \"registration_recheck_successes\": %llu,\n",
          (unsigned long long)(b1->registration_recheck_successes - b0->registration_recheck_successes));
  fprintf(stdout, "    \"actual_suspensions\": %llu,\n",
          (unsigned long long)(b1->actual_suspensions - b0->actual_suspensions));
  fprintf(stdout, "    \"notifications\": %llu,\n",
          (unsigned long long)(b1->notifications - b0->notifications));
  fprintf(stdout, "    \"cancellations\": %llu,\n",
          (unsigned long long)(b1->cancellations - b0->cancellations));
  fprintf(stdout, "    \"attributed_wakes\": %llu,\n",
          (unsigned long long)attr_wakes);
  fprintf(stdout, "    \"unattributed_wakes\": %llu\n",
          (unsigned long long)unattr_wakes);
  fprintf(stdout, "  },\n");

  fprintf(stdout, "  \"handle_counters\": {\n");
  fprintf(stdout, "    \"body_uv_async_init_calls\": %llu,\n",
          (unsigned long long)(b1->uv_async_init_calls - b0->uv_async_init_calls));
  fprintf(stdout, "    \"body_uv_async_send_calls\": %llu,\n",
          (unsigned long long)(b1->uv_async_send_calls - b0->uv_async_send_calls));
  fprintf(stdout, "    \"body_uv_async_close_calls\": %llu,\n",
          (unsigned long long)(b1->uv_async_close_calls - b0->uv_async_close_calls));
  fprintf(stdout, "    \"body_uv_close_total_calls\": %llu,\n",
          (unsigned long long)(b1->uv_close_total_calls - b0->uv_close_total_calls));
  fprintf(stdout, "    \"body_uv_async_close_callbacks\": %llu,\n",
          (unsigned long long)(b1->uv_async_close_callbacks - b0->uv_async_close_callbacks));
  fprintf(stdout, "    \"body_uv_loop_close_calls\": %llu,\n",
          (unsigned long long)(b1->uv_loop_close_calls - b0->uv_loop_close_calls));
  fprintf(stdout, "    \"body_uv_loop_close_successes\": %llu,\n",
          (unsigned long long)(b1->uv_loop_close_successes - b0->uv_loop_close_successes));
  fprintf(stdout, "    \"body_uv_async_loop_retirements\": %llu,\n",
          (unsigned long long)(b1->uv_async_loop_retirements - b0->uv_async_loop_retirements));
  fprintf(stdout, "    \"whole_case_uv_async_init_calls\": %llu,\n",
          (unsigned long long)(g2->uv_async_init_calls - s0->uv_async_init_calls));
  fprintf(stdout, "    \"whole_case_uv_async_close_calls\": %llu,\n",
          (unsigned long long)(g2->uv_async_close_calls - s0->uv_async_close_calls));
  fprintf(stdout, "    \"whole_case_uv_async_close_callbacks\": %llu,\n",
          (unsigned long long)(g2->uv_async_close_callbacks - s0->uv_async_close_callbacks));
  fprintf(stdout, "    \"whole_case_uv_loop_close_calls\": %llu,\n",
          (unsigned long long)(g2->uv_loop_close_calls - s0->uv_loop_close_calls));
  fprintf(stdout, "    \"whole_case_uv_loop_close_successes\": %llu,\n",
          (unsigned long long)(g2->uv_loop_close_successes - s0->uv_loop_close_successes));
  fprintf(stdout, "    \"whole_case_uv_async_loop_retirements\": %llu\n",
          (unsigned long long)(g2->uv_async_loop_retirements - s0->uv_async_loop_retirements));
  fprintf(stdout, "  },\n");

  fprintf(stdout, "  \"lua_memory\": {\n");
  fprintf(stdout, "    \"host_setup_start_bytes\": %lld,\n", (long long)g_probe.setup_start_lua_bytes);
  fprintf(stdout, "    \"host_body_start_bytes\": %lld,\n", (long long)g_probe.body_start_lua_bytes);
  fprintf(stdout, "    \"host_body_stop_bytes\": %lld,\n", (long long)g_probe.body_stop_lua_bytes);
  fprintf(stdout, "    \"host_workers_retired_bytes\": %lld,\n", (long long)g_probe.workers_retired_lua_bytes);
  fprintf(stdout, "    \"host_post_gc1_bytes\": %lld,\n", (long long)g_probe.post_gc1_lua_bytes);
  fprintf(stdout, "    \"host_post_gc2_bytes\": %lld,\n", (long long)g_probe.post_gc2_lua_bytes);
  fprintf(stdout, "    \"host_post_gc2_minus_setup_start_bytes\": %lld,\n",
          (long long)(g_probe.post_gc2_lua_bytes - g_probe.setup_start_lua_bytes));
  fprintf(stdout, "    \"body_alloc_calls\": %llu,\n",
          (unsigned long long)(b1->lua_alloc_calls - b0->lua_alloc_calls));
  fprintf(stdout, "    \"body_realloc_calls\": %llu,\n",
          (unsigned long long)(b1->lua_realloc_calls - b0->lua_realloc_calls));
  fprintf(stdout, "    \"body_free_calls\": %llu,\n",
          (unsigned long long)(b1->lua_free_calls - b0->lua_free_calls));
  fprintf(stdout, "    \"body_requested_bytes\": %llu,\n",
          (unsigned long long)(b1->lua_requested_bytes - b0->lua_requested_bytes));
  fprintf(stdout, "    \"whole_case_live_delta_bytes\": %lld\n",
          (long long)(g2->lua_live_delta_bytes - s0->lua_live_delta_bytes));
  fprintf(stdout, "  },\n");

  fprintf(stdout, "  \"native_memory\": {\n");
  fprintf(stdout, "    \"ledger_coverage\": \"interposed native allocation traffic and signed net delta; not complete retained memory\",\n");
  fprintf(stdout, "    \"body_malloc_calls\": %llu,\n",
          (unsigned long long)(b1->native_malloc_calls - b0->native_malloc_calls));
  fprintf(stdout, "    \"body_calloc_calls\": %llu,\n",
          (unsigned long long)(b1->native_calloc_calls - b0->native_calloc_calls));
  fprintf(stdout, "    \"body_realloc_calls\": %llu,\n",
          (unsigned long long)(b1->native_realloc_calls - b0->native_realloc_calls));
  fprintf(stdout, "    \"body_free_calls\": %llu,\n",
          (unsigned long long)(b1->native_free_calls - b0->native_free_calls));
  fprintf(stdout, "    \"body_requested_bytes\": %llu,\n",
          (unsigned long long)(b1->native_requested_bytes - b0->native_requested_bytes));
  fprintf(stdout, "    \"body_usable_live_delta_bytes\": %lld,\n",
          (long long)(b1->native_usable_live_bytes - b0->native_usable_live_bytes));
  fprintf(stdout, "    \"body_usable_peak_delta_bytes\": %lld,\n",
          (long long)(b1->native_usable_peak_bytes - b0->native_usable_live_bytes));
  fprintf(stdout, "    \"whole_case_post_gc2_live_blocks_delta\": %lld,\n",
          (long long)(g2->native_live_blocks - s0->native_live_blocks));
  fprintf(stdout, "    \"whole_case_post_gc2_usable_bytes_delta\": %lld\n",
          (long long)(g2->native_usable_live_bytes - s0->native_usable_live_bytes));
  fprintf(stdout, "  },\n");

  uint64_t out_mc_calls = b1->outside_lua_alloc_memcpy_calls - b0->outside_lua_alloc_memcpy_calls;
  uint64_t out_mc_bytes = b1->outside_lua_alloc_memcpy_bytes - b0->outside_lua_alloc_memcpy_bytes;
  uint64_t in_mc_calls = b1->inside_lua_alloc_memcpy_calls - b0->inside_lua_alloc_memcpy_calls;
  uint64_t in_mc_bytes = b1->inside_lua_alloc_memcpy_bytes - b0->inside_lua_alloc_memcpy_bytes;

  fprintf(stdout, "  \"copy_traffic\": {\n");
  fprintf(stdout, "    \"analytical_reference_bytes_per_op\": %lld,\n",
          (long long)g_probe.payload_wire_bytes_per_op);
  fprintf(stdout, "    \"payload_wire_bytes_per_op\": null,\n");
  fprintf(stdout, "    \"total_payload_wire_bytes\": null,\n");
  fprintf(stdout, "    \"coverage\": \"interposed memcpy + memmove only; excludes inlined copies and libc internal copies\",\n");
  fprintf(stdout, "    \"body_interposed_memcpy_calls\": %llu,\n",
          (unsigned long long)(out_mc_calls + in_mc_calls));
  fprintf(stdout, "    \"body_interposed_memcpy_bytes\": %llu,\n",
          (unsigned long long)(out_mc_bytes + in_mc_bytes));
  fprintf(stdout, "    \"body_outside_lua_alloc_memcpy_calls\": %llu,\n",
          (unsigned long long)out_mc_calls);
  fprintf(stdout, "    \"body_outside_lua_alloc_memcpy_bytes\": %llu,\n",
          (unsigned long long)out_mc_bytes);
  fprintf(stdout, "    \"body_inside_lua_alloc_memcpy_calls\": %llu,\n",
          (unsigned long long)in_mc_calls);
  fprintf(stdout, "    \"body_inside_lua_alloc_memcpy_bytes\": %llu\n",
          (unsigned long long)in_mc_bytes);
  fprintf(stdout, "  },\n");

  fprintf(stdout, "  \"process_peak_rss_kib\": %ld\n", peak_rss_kib);
  fprintf(stdout, "}\n");
  fflush(stdout);
  return 1;
}
