#include <limits.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <sys/stat.h>

#include "lobject.h"
#include "lua.h"

#include <uv.h>

#include "titan.h"
#include "titan/uv.h"

/* C99-compatible compile-time assertions for the public 1-based/0-based map. */
#define TITAN_UV_STATIC_ASSERT(name, condition)                                \
  typedef char titan_uv_static_assert_##name[(condition) ? 1 : -1]

TITAN_UV_STATIC_ASSERT(native_slot,
                       TITAN_UV_OWNER_NATIVE_LUA_SLOT - 1 ==
                           TITAN_UV_OWNER_NATIVE_C_INDEX);
TITAN_UV_STATIC_ASSERT(storage_slot,
                       TITAN_UV_OWNER_STORAGE_LUA_SLOT - 1 ==
                           TITAN_UV_OWNER_STORAGE_C_INDEX);
TITAN_UV_STATIC_ASSERT(main_thread_slot,
                       TITAN_UV_OWNER_MAIN_THREAD_LUA_SLOT - 1 ==
                           TITAN_UV_OWNER_MAIN_THREAD_C_INDEX);
TITAN_UV_STATIC_ASSERT(module_slot,
                       TITAN_UV_OWNER_MODULE_LUA_SLOT - 1 ==
                           TITAN_UV_OWNER_MODULE_C_INDEX);
TITAN_UV_STATIC_ASSERT(dispatcher_slot,
                       TITAN_UV_OWNER_DISPATCHER_LUA_SLOT - 1 ==
                           TITAN_UV_OWNER_DISPATCHER_C_INDEX);
TITAN_UV_STATIC_ASSERT(root_slot,
                       TITAN_UV_OWNER_ROOT_LUA_SLOT - 1 ==
                           TITAN_UV_OWNER_ROOT_C_INDEX);
TITAN_UV_STATIC_ASSERT(metadata_slot,
                       TITAN_UV_OWNER_METADATA_LUA_SLOT - 1 ==
                           TITAN_UV_OWNER_METADATA_C_INDEX);
TITAN_UV_STATIC_ASSERT(buffer_slot,
                       TITAN_UV_OWNER_BUFFER_LUA_SLOT - 1 ==
                           TITAN_UV_OWNER_BUFFER_C_INDEX);
TITAN_UV_STATIC_ASSERT(slot_count,
                       (int)TITAN_UV_OWNER_LUA_SLOT_COUNT ==
                           (int)TITAN_UV_OWNER_C_INDEX_COUNT);
TITAN_UV_STATIC_ASSERT(fs_result_fits_lua_integer,
                       sizeof(ssize_t) <= sizeof(lua_Integer));

typedef void (*titan_uv_dispatch_func)(lua_State *L, Udata *_mod,
                                       CClosure *_fn, Udata *owner,
                                       lua_Integer event_kind,
                                       lua_Integer result, size_t size);

/*
 * The Runtime pending/resource table strongly roots owner while libuv can call
 * us.  These fixed fields are therefore trusted in exactly the same way as the
 * four fixed coroutine-owner fields read by titan_coro_entry.
 */
static void titan_uvshim_dispatch(Udata *owner, lua_Integer event_kind,
                                  lua_Integer result, size_t size) {
  lua_State *L =
      thvalue(&owner->uv[TITAN_UV_OWNER_MAIN_THREAD_C_INDEX].uv);
  Udata *M = uvalue(&owner->uv[TITAN_UV_OWNER_MODULE_C_INDEX].uv);
  CClosure *dispatcher =
      clCvalue(&owner->uv[TITAN_UV_OWNER_DISPATCHER_C_INDEX].uv);
  titan_uv_dispatch_func dispatch =
      titan_cast_func(titan_uv_dispatch_func,
                      pvalue(&dispatcher->upvalue[2]));

  /* Direct native Titan entry: the trusted dispatcher owns its outer catch. */
  dispatch(L, M, NULL, owner, event_kind, result, size);
}

void titan_uvshim_timer_set_data(uv_timer_t *timer, void *data) {
  uv_handle_set_data((uv_handle_t *)timer, data);
}

void *titan_uvshim_timer_get_data(const uv_timer_t *timer) {
  return uv_handle_get_data((const uv_handle_t *)timer);
}

int titan_uvshim_timer_is_closing(const uv_timer_t *timer) {
  return uv_is_closing((const uv_handle_t *)timer);
}

void titan_uvshim_timer_close(uv_timer_t *timer) {
  uv_close((uv_handle_t *)timer, titan_uvshim_close_cb);
}

void titan_uvshim_fs_set_data(uv_fs_t *req, void *data) {
  uv_req_set_data((uv_req_t *)req, data);
}

void *titan_uvshim_fs_get_data(const uv_fs_t *req) {
  return uv_req_get_data((const uv_req_t *)req);
}

int titan_uvshim_fs_cancel(uv_fs_t *req) {
  return uv_cancel((uv_req_t *)req);
}

int titan_uvshim_fs_scandir_next(uv_fs_t *req, void *opaque_entry) {
  int status = uv_fs_scandir_next(req, (uv_dirent_t *)opaque_entry);
  return status == UV_EOF ? 1 : status;
}

const char *titan_uvshim_dirent_name(const void *opaque_entry) {
  return ((const uv_dirent_t *)opaque_entry)->name;
}

int titan_uvshim_error_eio(void) {
  return UV_EIO;
}

void titan_uvshim_timer_cb(uv_timer_t *timer) {
  Udata *owner = (Udata *)uv_handle_get_data((uv_handle_t *)timer);
  titan_uvshim_dispatch(owner, TITAN_UV_EVENT_TIMER, 0, 0);
}

void titan_uvshim_close_cb(uv_handle_t *handle) {
  Udata *owner = (Udata *)uv_handle_get_data(handle);
  titan_uvshim_dispatch(owner, TITAN_UV_EVENT_HANDLE_CLOSE, 0, 0);
}

void titan_uvshim_fs_cb(uv_fs_t *req) {
  Udata *owner = (Udata *)uv_req_get_data((uv_req_t *)req);
  lua_Integer result = (lua_Integer)uv_fs_get_result(req);
  titan_uvshim_dispatch(owner, TITAN_UV_EVENT_FS, result, 0);
}

int titan_uvshim_buf_init(void *buf, char *base, int64_t len) {
  uv_buf_t *uvbuf = (uv_buf_t *)buf;

  if (len < 0 || (uint64_t)len > UINT_MAX) {
    return UV_EINVAL;
  }
  *uvbuf = uv_buf_init(base, (unsigned int)len);
  return 0;
}

int titan_uvshim_allocation_length_is_valid(int64_t length) {
  return length >= 0 && (uint64_t)length <= SIZE_MAX;
}

int titan_uvshim_buf_length_is_valid(int64_t length) {
  return titan_uvshim_allocation_length_is_valid(length) &&
         (uint64_t)length <= UINT_MAX;
}

int titan_uvshim_buf_init_slice(void *buf, char *base, int64_t total,
                                int64_t offset, int64_t length) {
  if (base == NULL || total < 0 || offset < 0 || length < 0 ||
      offset > total || length > total - offset ||
      (uint64_t)total > SIZE_MAX || (uint64_t)offset > PTRDIFF_MAX ||
      (uint64_t)length > UINT_MAX) {
    return UV_EINVAL;
  }
  return titan_uvshim_buf_init(buf, base + offset, length);
}

int titan_uvshim_bytes_copy(char *destination, int64_t capacity,
                            const char *source, int64_t length) {
  if (destination == NULL || source == NULL || capacity < 0 || length < 0 ||
      capacity < length || (uint64_t)capacity > SIZE_MAX ||
      (uint64_t)length > SIZE_MAX) {
    return UV_EINVAL;
  }
  memcpy(destination, source, (size_t)length);
  return 0;
}

int titan_uvshim_text_copy(char *destination, int64_t capacity,
                           const char *source, int64_t length) {
  if (destination == NULL || source == NULL || length < 0 ||
      capacity <= 0 || length > INT64_MAX - 1 || capacity != length + 1) {
    return UV_EINVAL;
  }
  if ((uint64_t)capacity > SIZE_MAX || (uint64_t)length > PTRDIFF_MAX) {
    return UV_EINVAL;
  }
  if (memchr(source, '\0', (size_t)length) != NULL) {
    return UV_EINVAL;
  }
  memcpy(destination, source, (size_t)length);
  destination[length] = '\0';
  return 0;
}

int titan_uvshim_stat_extract(const void *opaque_statbuf, int64_t *size,
                              int64_t *mode, int64_t *modified_seconds,
                              int64_t *modified_nanoseconds, int *kind) {
  const uv_stat_t *statbuf = (const uv_stat_t *)opaque_statbuf;

  if (statbuf == NULL || size == NULL || mode == NULL ||
      modified_seconds == NULL || modified_nanoseconds == NULL ||
      kind == NULL) {
    return UV_EINVAL;
  }
  if (statbuf->st_size > INT64_MAX || statbuf->st_mode > INT64_MAX) {
    return UV_EOVERFLOW;
  }

  *size = (int64_t)statbuf->st_size;
  *mode = (int64_t)statbuf->st_mode;
  *modified_seconds = statbuf->st_mtim.tv_sec;
  *modified_nanoseconds = statbuf->st_mtim.tv_nsec;
  if (S_ISREG((mode_t)statbuf->st_mode)) {
    *kind = TITAN_UV_STAT_FILE;
  } else if (S_ISDIR((mode_t)statbuf->st_mode)) {
    *kind = TITAN_UV_STAT_DIRECTORY;
  } else if (S_ISLNK((mode_t)statbuf->st_mode)) {
    *kind = TITAN_UV_STAT_SYMLINK;
  } else {
    *kind = TITAN_UV_STAT_OTHER;
  }
  return 0;
}

struct titan_uv_walk_summary {
  int count;
  uv_handle_type first_type;
};

static void titan_uvshim_walk_summary_cb(uv_handle_t *handle, void *arg) {
  struct titan_uv_walk_summary *summary =
      (struct titan_uv_walk_summary *)arg;
  if (summary->count == 0)
    summary->first_type = uv_handle_get_type(handle);
  summary->count++;
}

static struct titan_uv_walk_summary titan_uvshim_walk_summary(
    uv_loop_t *loop) {
  struct titan_uv_walk_summary summary = {0, UV_UNKNOWN_HANDLE};
  uv_walk(loop, titan_uvshim_walk_summary_cb, &summary);
  return summary;
}

int titan_uvshim_loop_handle_count(uv_loop_t *loop) {
  return titan_uvshim_walk_summary(loop).count;
}

const char *titan_uvshim_loop_first_handle_type(uv_loop_t *loop) {
  struct titan_uv_walk_summary summary = titan_uvshim_walk_summary(loop);
  const char *name = uv_handle_type_name(summary.first_type);
  return name != NULL ? name : "unknown";
}

int titan_uvshim_status_is_ebusy(int status) {
  return status == UV_EBUSY;
}
