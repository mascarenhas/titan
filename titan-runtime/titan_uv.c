#include <stddef.h>
#include <stdint.h>

#include "lobject.h"
#include "lua.h"

#include <uv.h>

#include "titan.h"
#include "titan/uv.h"

typedef void (*titan_uv_noarg_callback_func)(lua_State *L, Udata *_mod,
                                             CClosure *_fn, Udata *owner);
typedef void (*titan_uv_integer_callback_func)(lua_State *L, Udata *_mod,
                                               CClosure *_fn, Udata *owner,
                                               lua_Integer result);
typedef void (*titan_uv_two_integer_callback_func)(lua_State *L, Udata *_mod,
                                                   CClosure *_fn,
                                                   Udata *owner,
                                                   lua_Integer first,
                                                   lua_Integer second);
typedef void (*titan_uv_size_pointer_callback_func)(lua_State *L, Udata *_mod,
                                                    CClosure *_fn,
                                                    Udata *owner, size_t size,
                                                    void *pointer);
typedef void (*titan_uv_integer_pointer_callback_func)(lua_State *L,
                                                       Udata *_mod,
                                                       CClosure *_fn,
                                                       Udata *owner,
                                                       lua_Integer result,
                                                       void *pointer);
typedef void (*titan_uv_pointer_callback_func)(lua_State *L, Udata *_mod,
                                               CClosure *_fn, Udata *owner,
                                               void *pointer);

typedef struct titan_uvshim_callback_context {
  lua_State *L;
  Udata *module;
  CClosure *closure;
  void *entry;
  int stack_top;
} titan_uvshim_callback_context;

/*
 * Titan strongly roots each request/handle continuation record while libuv
 * can call us. The owning Runtime stores its stable Lua main thread once in
 * uv_loop_t data. This helper only extracts the common callback context; each
 * libuv-shaped trampoline below invokes its own exact Titan callback handler.
 */
static titan_uvshim_callback_context titan_uvshim_callback_context_for(
    uv_loop_t *loop, Udata *owner, size_t callback_index) {
  titan_uvshim_callback_context context;
  CClosure *callback = clCvalue(&owner->uv[callback_index].uv);

  context.L = (lua_State *)uv_loop_get_data(loop);
  context.module = uvalue(&callback->upvalue[0]);
  context.closure = callback;
  context.entry = pvalue(&callback->upvalue[2]);
  context.stack_top = lua_gettop(context.L);
  /* Direct Titan callers must stack-root GC arguments. In particular, a
   * one-shot callback may clear the Task's request root while it resumes, and
   * close_cb removes its handle root before resuming its waiter. */
  titan_pushmodule(context.L, owner);
  return context;
}

static void titan_uvshim_callback_context_release(
    titan_uvshim_callback_context *context) {
  lua_settop(context->L, context->stack_top);
}

void titan_uvshim_signal_cb(uv_signal_t *signal, int signum) {
  Udata *owner = (Udata *)uv_handle_get_data((uv_handle_t *)signal);
  titan_uvshim_callback_context context = titan_uvshim_callback_context_for(
      uv_handle_get_loop((uv_handle_t *)signal), owner,
      TITAN_UV_PRIMARY_CALLBACK_C_INDEX);
  titan_uv_integer_callback_func callback = titan_cast_func(
      titan_uv_integer_callback_func, context.entry);
  callback(context.L, context.module, context.closure, owner, signum);
  titan_uvshim_callback_context_release(&context);
}

void titan_uvshim_process_exit_cb(uv_process_t *process, int64_t exit_status,
                                  int term_signal) {
  Udata *owner = (Udata *)uv_handle_get_data((uv_handle_t *)process);
  titan_uvshim_callback_context context = titan_uvshim_callback_context_for(
      uv_handle_get_loop((uv_handle_t *)process), owner,
      TITAN_UV_PRIMARY_CALLBACK_C_INDEX);
  titan_uv_two_integer_callback_func callback = titan_cast_func(
      titan_uv_two_integer_callback_func, context.entry);

  callback(context.L, context.module, context.closure, owner,
           (lua_Integer)exit_status, (lua_Integer)term_signal);
  titan_uvshim_callback_context_release(&context);
}

void titan_uvshim_getaddrinfo_cb(uv_getaddrinfo_t *req, int status,
                                 struct addrinfo *result) {
  Udata *owner = (Udata *)uv_req_get_data((uv_req_t *)req);
  titan_uvshim_callback_context context = titan_uvshim_callback_context_for(
      req->loop, owner, TITAN_UV_PRIMARY_CALLBACK_C_INDEX);
  titan_uv_integer_pointer_callback_func callback = titan_cast_func(
      titan_uv_integer_pointer_callback_func, context.entry);
  callback(context.L, context.module, context.closure, owner, status, result);
  titan_uvshim_callback_context_release(&context);
}

void titan_uvshim_connect_cb(uv_connect_t *req, int status) {
  Udata *owner = (Udata *)uv_req_get_data((uv_req_t *)req);
  titan_uvshim_callback_context context = titan_uvshim_callback_context_for(
      uv_handle_get_loop((uv_handle_t *)req->handle), owner,
      TITAN_UV_PRIMARY_CALLBACK_C_INDEX);
  titan_uv_integer_callback_func callback = titan_cast_func(
      titan_uv_integer_callback_func, context.entry);
  callback(context.L, context.module, context.closure, owner, status);
  titan_uvshim_callback_context_release(&context);
}

void titan_uvshim_write_cb(uv_write_t *req, int status) {
  Udata *owner = (Udata *)uv_req_get_data((uv_req_t *)req);
  titan_uvshim_callback_context context = titan_uvshim_callback_context_for(
      uv_handle_get_loop((uv_handle_t *)req->handle), owner,
      TITAN_UV_PRIMARY_CALLBACK_C_INDEX);
  titan_uv_integer_callback_func callback = titan_cast_func(
      titan_uv_integer_callback_func, context.entry);
  callback(context.L, context.module, context.closure, owner, status);
  titan_uvshim_callback_context_release(&context);
}

void titan_uvshim_shutdown_cb(uv_shutdown_t *req, int status) {
  Udata *owner = (Udata *)uv_req_get_data((uv_req_t *)req);
  titan_uvshim_callback_context context = titan_uvshim_callback_context_for(
      uv_handle_get_loop((uv_handle_t *)req->handle), owner,
      TITAN_UV_PRIMARY_CALLBACK_C_INDEX);
  titan_uv_integer_callback_func callback = titan_cast_func(
      titan_uv_integer_callback_func, context.entry);
  callback(context.L, context.module, context.closure, owner, status);
  titan_uvshim_callback_context_release(&context);
}

void titan_uvshim_alloc_cb(uv_handle_t *handle, size_t suggested_size,
                           uv_buf_t *buf) {
  Udata *owner = (Udata *)uv_handle_get_data(handle);
  titan_uvshim_callback_context context;
  titan_uv_size_pointer_callback_func callback;

  context = titan_uvshim_callback_context_for(
      uv_handle_get_loop(handle), owner, TITAN_UV_PRIMARY_CALLBACK_C_INDEX);
  callback = titan_cast_func(titan_uv_size_pointer_callback_func,
                             context.entry);
  callback(context.L, context.module, context.closure, owner, suggested_size,
           buf);
  titan_uvshim_callback_context_release(&context);
}

void titan_uvshim_read_cb(uv_stream_t *stream, ssize_t nread,
                          const uv_buf_t *buf) {
  Udata *owner = (Udata *)uv_handle_get_data((uv_handle_t *)stream);
  titan_uvshim_callback_context context = titan_uvshim_callback_context_for(
      uv_handle_get_loop((uv_handle_t *)stream), owner,
      TITAN_UV_READ_CALLBACK_C_INDEX);
  titan_uv_integer_callback_func callback = titan_cast_func(
      titan_uv_integer_callback_func, context.entry);
  (void)buf;
  callback(context.L, context.module, context.closure, owner,
           (lua_Integer)nread);
  titan_uvshim_callback_context_release(&context);
}

void titan_uvshim_connection_cb(uv_stream_t *server, int status) {
  Udata *owner = (Udata *)uv_handle_get_data((uv_handle_t *)server);
  titan_uvshim_callback_context context = titan_uvshim_callback_context_for(
      uv_handle_get_loop((uv_handle_t *)server), owner,
      TITAN_UV_CONNECTION_CALLBACK_C_INDEX);
  titan_uv_integer_callback_func callback = titan_cast_func(
      titan_uv_integer_callback_func, context.entry);
  callback(context.L, context.module, context.closure, owner, status);
  titan_uvshim_callback_context_release(&context);
}

void titan_uvshim_timer_cb(uv_timer_t *timer) {
  Udata *owner = (Udata *)uv_handle_get_data((uv_handle_t *)timer);
  titan_uvshim_callback_context context = titan_uvshim_callback_context_for(
      uv_handle_get_loop((uv_handle_t *)timer), owner,
      TITAN_UV_PRIMARY_CALLBACK_C_INDEX);
  titan_uv_noarg_callback_func callback = titan_cast_func(
      titan_uv_noarg_callback_func, context.entry);
  callback(context.L, context.module, context.closure, owner);
  titan_uvshim_callback_context_release(&context);
}

void titan_uvshim_close_cb(uv_handle_t *handle) {
  Udata *owner = (Udata *)uv_handle_get_data(handle);
  titan_uvshim_callback_context context = titan_uvshim_callback_context_for(
      uv_handle_get_loop(handle), owner, TITAN_UV_PRIMARY_CALLBACK_C_INDEX);
  titan_uv_noarg_callback_func callback = titan_cast_func(
      titan_uv_noarg_callback_func, context.entry);
  callback(context.L, context.module, context.closure, owner);
  titan_uvshim_callback_context_release(&context);
}

void titan_uvshim_walk_cb(uv_handle_t *handle, void *arg) {
  Udata *owner = (Udata *)arg;
  titan_uvshim_callback_context context = titan_uvshim_callback_context_for(
      uv_handle_get_loop(handle), owner, TITAN_UV_PRIMARY_CALLBACK_C_INDEX);
  titan_uv_pointer_callback_func callback = titan_cast_func(
      titan_uv_pointer_callback_func, context.entry);
  callback(context.L, context.module, context.closure, owner, handle);
  titan_uvshim_callback_context_release(&context);
}

void titan_uvshim_fs_cb(uv_fs_t *req) {
  Udata *owner = (Udata *)uv_req_get_data((uv_req_t *)req);
  titan_uvshim_callback_context context = titan_uvshim_callback_context_for(
      req->loop, owner, TITAN_UV_PRIMARY_CALLBACK_C_INDEX);
  titan_uv_noarg_callback_func callback = titan_cast_func(
      titan_uv_noarg_callback_func, context.entry);
  callback(context.L, context.module, context.closure, owner);
  titan_uvshim_callback_context_release(&context);
}
