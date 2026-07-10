#include <limits.h>
#include <stddef.h>
#include <stdint.h>

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
