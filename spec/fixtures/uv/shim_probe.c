#include <assert.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "lauxlib.h"
#include "lobject.h"
#include "lua.h"

#include <uv.h>

#include "titan.h"
#include "titan/uv.h"

static lua_State *expected_L;
static Udata *expected_module;
static uv_timer_t *expected_timer;
static uv_fs_t *expected_fs;
static uv_getaddrinfo_t *expected_dns;
static uv_tcp_t *expected_tcp;
static uv_signal_t *expected_signal;
static int lua_wrapper_calls;
static int timer_dispatches;
static int close_dispatches;
static int fs_dispatches;
static int dns_dispatches;
static int tcp_close_dispatches;
static int signal_dispatches;
static int signal_close_dispatches;
static int fs_cleanups;
static int timer_dispatch_finished;
static int signal_dispatch_finished;

static int forbidden_lua_wrapper(lua_State *L) {
  (void)L;
  lua_wrapper_calls++;
  return 0;
}

static void test_dispatch(lua_State *L, Udata *_mod, CClosure *_fn,
                          Udata *owner, lua_Integer event_kind,
                          lua_Integer result, size_t size, void *pointer) {
  assert(L == expected_L);
  assert(_mod == expected_module);
  assert(_fn == NULL);
  assert(owner != NULL);
  assert(size == 0);

  if (event_kind == TITAN_UV_EVENT_TIMER) {
    uv_timer_t *timer =
        (uv_timer_t *)pvalue(&owner->uv[TITAN_UV_OWNER_NATIVE_C_INDEX].uv);
    assert(timer == expected_timer);
    assert(result == 0);
    assert(pointer == NULL);
    assert(timer_dispatches == 0);
    timer_dispatches++;

    /* Arm the terminal close while callback A is driving its continuation. */
    assert(!titan_uvshim_timer_is_closing(timer));
    titan_uvshim_timer_close(timer);
    assert(titan_uvshim_timer_is_closing(timer));
    timer_dispatch_finished = 1;
  } else if (event_kind == TITAN_UV_EVENT_HANDLE_CLOSE) {
    void *native =
        pvalue(&owner->uv[TITAN_UV_OWNER_NATIVE_C_INDEX].uv);
    assert(result == 0);
    assert(pointer == NULL);
    if (native == expected_timer) {
      assert(timer_dispatch_finished == 1);
      close_dispatches++;
    } else if (native == expected_signal) {
      assert(signal_dispatch_finished == 1);
      signal_close_dispatches++;
    } else {
      assert(native == expected_tcp);
      tcp_close_dispatches++;
    }
  } else if (event_kind == TITAN_UV_EVENT_FS) {
    uv_fs_t *req =
        (uv_fs_t *)pvalue(&owner->uv[TITAN_UV_OWNER_NATIVE_C_INDEX].uv);
    const uv_stat_t *statbuf;
    const char *path;

    assert(req == expected_fs);
    assert(result == 0);
    assert(pointer == NULL);
    path = uv_fs_get_path(req);
    statbuf = uv_fs_get_statbuf(req);
    assert(path != NULL);
    assert(strcmp(path, ".") == 0);
    assert(statbuf != NULL);

    /* Borrowed request data is consumed before the one terminal cleanup. */
    uv_fs_req_cleanup(req);
    fs_cleanups++;
    fs_dispatches++;
  } else if (event_kind == TITAN_UV_EVENT_GETADDRINFO) {
    uv_getaddrinfo_t *req =
        (uv_getaddrinfo_t *)pvalue(
            &owner->uv[TITAN_UV_OWNER_NATIVE_C_INDEX].uv);
    titan_uvshim_address *addresses;
    int64_t count;

    assert(req == expected_dns);
    assert(result == 0);
    assert(pointer != NULL);
    count = titan_uvshim_addrinfo_count(pointer);
    assert(count > 0);
    assert((uint64_t)count <= SIZE_MAX / sizeof(*addresses));
    addresses = calloc((size_t)count, sizeof(*addresses));
    assert(addresses != NULL);
    assert(titan_uvshim_addrinfo_copy(pointer, addresses, count) == 0);
    free(addresses);
    titan_uvshim_addrinfo_free(pointer);
    dns_dispatches++;
  } else if (event_kind == TITAN_UV_EVENT_SIGNAL) {
    uv_signal_t *signal =
        (uv_signal_t *)pvalue(
            &owner->uv[TITAN_UV_OWNER_NATIVE_C_INDEX].uv);
    int usr1 = titan_uvshim_signal_number("usr1");

    assert(signal == expected_signal);
    assert(result == usr1);
    assert(pointer == NULL);
    assert(signal_dispatches == 0);
    signal_dispatches++;

    /* Titan's trusted dispatcher stops/closes before running user code. */
    assert(titan_uvshim_signal_stop(signal) == 0);
    assert(!titan_uvshim_signal_is_closing(signal));
    titan_uvshim_signal_close(signal);
    assert(titan_uvshim_signal_is_closing(signal));
    signal_dispatch_finished = 1;
  } else {
    assert(!"unexpected shim event kind");
  }
}

static int registry_ref_for_new_udata(lua_State *L, int nuvalue) {
  lua_newuserdatauv(L, 0, nuvalue);
  return luaL_ref(L, LUA_REGISTRYINDEX);
}

static int make_dispatcher(lua_State *L, int module_ref) {
  static const char dispatcher_tag[] = "uv dispatcher type tag";

  lua_rawgeti(L, LUA_REGISTRYINDEX, module_ref);
  lua_pushlightuserdata(L, (void *)dispatcher_tag);
  lua_pushlightuserdata(L, titan_cast_func(void *, test_dispatch));
  lua_pushcclosure(L, forbidden_lua_wrapper, 3);
  return luaL_ref(L, LUA_REGISTRYINDEX);
}

static Udata *push_owner(lua_State *L, void *native, int module_ref,
                         int dispatcher_ref) {
  int owner_index;
  Udata *owner;

  lua_newuserdatauv(L, 0, TITAN_UV_OWNER_LUA_SLOT_COUNT);
  owner_index = lua_gettop(L);
  owner = uvalue(s2v(L->top.p - 1));

  lua_pushlightuserdata(L, native);
  assert(lua_setiuservalue(L, owner_index,
                          TITAN_UV_OWNER_NATIVE_LUA_SLOT) == 1);
  lua_newuserdatauv(L, 32, 0);
  assert(lua_setiuservalue(L, owner_index,
                          TITAN_UV_OWNER_STORAGE_LUA_SLOT) == 1);
  lua_pushthread(L);
  assert(lua_setiuservalue(L, owner_index,
                          TITAN_UV_OWNER_MAIN_THREAD_LUA_SLOT) == 1);
  lua_rawgeti(L, LUA_REGISTRYINDEX, module_ref);
  assert(lua_setiuservalue(L, owner_index,
                          TITAN_UV_OWNER_MODULE_LUA_SLOT) == 1);
  lua_rawgeti(L, LUA_REGISTRYINDEX, dispatcher_ref);
  assert(lua_setiuservalue(L, owner_index,
                          TITAN_UV_OWNER_DISPATCHER_LUA_SLOT) == 1);
  lua_pushliteral(L, "root");
  assert(lua_setiuservalue(L, owner_index,
                          TITAN_UV_OWNER_ROOT_LUA_SLOT) == 1);
  lua_pushliteral(L, "metadata");
  assert(lua_setiuservalue(L, owner_index,
                          TITAN_UV_OWNER_METADATA_LUA_SLOT) == 1);
  lua_pushliteral(L, "buffer");
  assert(lua_setiuservalue(L, owner_index,
                          TITAN_UV_OWNER_BUFFER_LUA_SLOT) == 1);

  return owner;
}

static void pending_store_and_pop(lua_State *L, int pending_ref, int key) {
  int owner_index = lua_gettop(L);

  lua_rawgeti(L, LUA_REGISTRYINDEX, pending_ref);
  lua_pushvalue(L, owner_index);
  lua_rawseti(L, -2, key);
  lua_pop(L, 2); /* pending table, then the owner's former stack anchor */
}

static void pending_remove(lua_State *L, int pending_ref, int key) {
  lua_rawgeti(L, LUA_REGISTRYINDEX, pending_ref);
  lua_pushnil(L);
  lua_rawseti(L, -2, key);
  lua_pop(L, 1);
}

static void test_slot_numbering(void) {
  assert(TITAN_UV_OWNER_NATIVE_LUA_SLOT - 1 ==
         TITAN_UV_OWNER_NATIVE_C_INDEX);
  assert(TITAN_UV_OWNER_STORAGE_LUA_SLOT - 1 ==
         TITAN_UV_OWNER_STORAGE_C_INDEX);
  assert(TITAN_UV_OWNER_MAIN_THREAD_LUA_SLOT - 1 ==
         TITAN_UV_OWNER_MAIN_THREAD_C_INDEX);
  assert(TITAN_UV_OWNER_MODULE_LUA_SLOT - 1 ==
         TITAN_UV_OWNER_MODULE_C_INDEX);
  assert(TITAN_UV_OWNER_DISPATCHER_LUA_SLOT - 1 ==
         TITAN_UV_OWNER_DISPATCHER_C_INDEX);
  assert(TITAN_UV_OWNER_ROOT_LUA_SLOT - 1 == TITAN_UV_OWNER_ROOT_C_INDEX);
  assert(TITAN_UV_OWNER_METADATA_LUA_SLOT - 1 ==
         TITAN_UV_OWNER_METADATA_C_INDEX);
  assert(TITAN_UV_OWNER_BUFFER_LUA_SLOT - 1 ==
         TITAN_UV_OWNER_BUFFER_C_INDEX);
  assert((int)TITAN_UV_OWNER_LUA_SLOT_COUNT ==
         (int)TITAN_UV_OWNER_C_INDEX_COUNT);
  assert(TITAN_UV_EVENT_TIMER == 1);
  assert(TITAN_UV_EVENT_HANDLE_CLOSE == 2);
  assert(TITAN_UV_EVENT_FS == 3);
  assert(TITAN_UV_EVENT_GETADDRINFO == 4);
  assert(TITAN_UV_EVENT_CONNECT == 5);
  assert(TITAN_UV_EVENT_WRITE == 6);
  assert(TITAN_UV_EVENT_SHUTDOWN == 7);
  assert(TITAN_UV_EVENT_STREAM_READ == 8);
  assert(TITAN_UV_EVENT_CONNECTION == 9);
  assert(TITAN_UV_EVENT_SIGNAL == 10);
}

static void test_os_helpers(void) {
  static const char env_name[] = "TITAN_UV_SHIM_PROBE_ENV";
  static const char env_value[] = "a deliberately resized environment value";
  char buffer[4096];
  size_t size;
  int status;

  assert(titan_uvshim_status_is_enobufs(UV_ENOBUFS));
  assert(!titan_uvshim_status_is_enobufs(UV_ENOENT));
  assert(titan_uvshim_status_is_enoent(UV_ENOENT));
  assert(!titan_uvshim_status_is_enoent(UV_ENOBUFS));
  assert(titan_uvshim_error_eoverflow() == UV_EOVERFLOW);
  assert(titan_uvshim_size_as_int64(0) == 0);
  assert(titan_uvshim_size_as_int64(42) == 42);
#if SIZE_MAX > INT64_MAX
  assert(titan_uvshim_size_as_int64(SIZE_MAX) == -1);
#else
  assert(titan_uvshim_size_as_int64(SIZE_MAX) == (int64_t)SIZE_MAX);
#endif

  assert(uv_os_unsetenv(env_name) == 0);
  size = sizeof(buffer);
  assert(uv_os_getenv(env_name, buffer, &size) == UV_ENOENT);
  assert(uv_os_setenv(env_name, env_value) == 0);
  size = 2;
  assert(uv_os_getenv(env_name, buffer, &size) == UV_ENOBUFS);
  assert(size == sizeof(env_value));
  size = sizeof(buffer);
  assert(uv_os_getenv(env_name, buffer, &size) == 0);
  assert(size == sizeof(env_value) - 1);
  assert(strcmp(buffer, env_value) == 0);
  assert(uv_os_setenv(env_name, "") == 0);
  size = sizeof(buffer);
  assert(uv_os_getenv(env_name, buffer, &size) == 0);
  assert(size == 0);
  assert(buffer[0] == '\0');
  assert(uv_os_unsetenv(env_name) == 0);

  size = sizeof(buffer);
  assert(uv_cwd(buffer, &size) == 0);
  assert(size > 0);
  assert(buffer[size] == '\0');
  assert(uv_chdir(buffer) == 0);

  size = sizeof(buffer);
  status = uv_os_homedir(buffer, &size);
  assert(status == 0);
  assert(size < sizeof(buffer));
  assert(buffer[size] == '\0');

  size = sizeof(buffer);
  status = uv_os_tmpdir(buffer, &size);
  assert(status == 0);
  assert(size < sizeof(buffer));
  assert(buffer[size] == '\0');

  size = sizeof(buffer);
  assert(uv_os_gethostname(buffer, &size) == 0);
  assert(size > 0 && size < sizeof(buffer));
  assert(buffer[size] == '\0');

  /* Linux and Darwin report a successful, explicitly NUL-terminated prefix. */
  size = 2;
  assert(uv_exepath(buffer, &size) == 0);
  assert(size == 1);
  assert(buffer[1] == '\0');
  size = sizeof(buffer);
  assert(uv_exepath(buffer, &size) == 0);
  assert(size > 0 && size < sizeof(buffer));
  assert(buffer[size] == '\0');

  assert((int64_t)uv_os_getpid() > 0);
  assert((int64_t)uv_os_getppid() > 0);
}

static void test_signal_mapping(void) {
  static const char *const names[] = {
      "hup", "int", "quit", "kill", "term", "usr1", "usr2"};
  size_t i;

  assert(titan_uvshim_signal_number(NULL) == UV_EINVAL);
  assert(titan_uvshim_signal_number("") == UV_EINVAL);
  assert(titan_uvshim_signal_number("USR1") == UV_EINVAL);
  assert(titan_uvshim_signal_name(-1) == NULL);
  for (i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
    int signum = titan_uvshim_signal_number(names[i]);
    assert(signum > 0);
    assert(strcmp(titan_uvshim_signal_name(signum), names[i]) == 0);
    assert(titan_uvshim_signal_is_waitable(signum) ==
           (strcmp(names[i], "kill") != 0));
  }
}

static void test_buffers(void) {
  char bytes[] = {'a', '\0', 'b', '\0', 'c'};
  uv_buf_t buf;
  size_t maximum_userdata = MAX_SIZE - udatamemoffset(0);

  assert(maximum_userdata <= INT64_MAX);
  assert(titan_uvshim_allocation_length_is_valid(0));
  assert(titan_uvshim_allocation_length_is_valid(
      (int64_t)maximum_userdata));
  if (maximum_userdata < INT64_MAX)
    assert(!titan_uvshim_allocation_length_is_valid(
        (int64_t)maximum_userdata + 1));

  assert(titan_uvshim_buf_init(&buf, bytes, sizeof(bytes)) == 0);
  assert(buf.base == bytes);
  assert(buf.len == sizeof(bytes));
  assert(memcmp(buf.base, bytes, sizeof(bytes)) == 0);

  assert(titan_uvshim_buf_init(&buf, NULL, 0) == 0);
  assert(buf.base == NULL);
  assert(buf.len == 0);

  assert(titan_uvshim_buf_init(&buf, bytes, -1) == UV_EINVAL);
  assert(titan_uvshim_buf_init(&buf, bytes, (int64_t)UINT_MAX + 1) ==
         UV_EINVAL);
}

static void test_binary_helpers(void) {
  const char haystack[] = {'a', '\0', 'b', 'a', '\0', 'b'};
  const char first[] = {'a', '\0', 'b'};
  const char crossing[] = {'b', 'a', '\0'};
  const char absent[] = {'b', '\0', 'a'};
  char destination[4] = {'x', 'x', 'x', 'x'};

  assert(titan_uvshim_bytes_find(haystack, sizeof(haystack), first,
                                 sizeof(first)) == 0);
  assert(titan_uvshim_bytes_find(haystack, sizeof(haystack), crossing,
                                 sizeof(crossing)) == 2);
  assert(titan_uvshim_bytes_find(haystack, sizeof(haystack), absent,
                                 sizeof(absent)) == -1);
  assert(titan_uvshim_bytes_find(haystack, sizeof(haystack), NULL, 0) == 0);
  assert(titan_uvshim_bytes_find(NULL, 0, first, sizeof(first)) == -1);
  assert(titan_uvshim_bytes_find(NULL, 1, first, sizeof(first)) == UV_EINVAL);
  assert(titan_uvshim_bytes_find(haystack, -1, first, sizeof(first)) ==
         UV_EINVAL);

  assert(titan_uvshim_bytes_slice_copy(destination, sizeof(destination),
                                       haystack, sizeof(haystack), 1, 4) == 0);
  assert(memcmp(destination, haystack + 1, sizeof(destination)) == 0);
  assert(titan_uvshim_bytes_slice_copy(NULL, 0, NULL, 0, 0, 0) == 0);
  assert(titan_uvshim_bytes_slice_copy(destination, sizeof(destination),
                                       haystack, sizeof(haystack), 4, 3) ==
         UV_EINVAL);
  assert(titan_uvshim_bytes_slice_copy(destination, 2, haystack,
                                       sizeof(haystack), 0, 3) == UV_EINVAL);
  assert(titan_uvshim_bytes_slice_copy(NULL, 3, haystack, sizeof(haystack),
                                       0, 3) == UV_EINVAL);
}

static void test_native_storage_layout(lua_State *L) {
  void *storage;
  uv_loop_t *loop;
  uv_timer_t *timer;
  uv_fs_t *fs;
  uv_buf_t *buf;
  uv_getaddrinfo_t *dns;
  uv_connect_t *connect;
  uv_write_t *write;
  uv_shutdown_t *shutdown;
  uv_tcp_t *tcp;
  uv_signal_t *signal;
  titan_uvshim_address *address;

  assert(sizeof(uv_loop_t) > 0);
  assert(_Alignof(uv_loop_t) > 0);
  storage = lua_newuserdatauv(L, sizeof(uv_loop_t), 0);
  assert((uintptr_t)storage % _Alignof(uv_loop_t) == 0);
  loop = (uv_loop_t *)storage;
  assert((void *)loop == storage);
  lua_pop(L, 1);

  assert(sizeof(uv_timer_t) > 0);
  assert(_Alignof(uv_timer_t) > 0);
  storage = lua_newuserdatauv(L, sizeof(uv_timer_t), 0);
  assert((uintptr_t)storage % _Alignof(uv_timer_t) == 0);
  timer = (uv_timer_t *)storage;
  assert((void *)timer == storage);
  lua_pop(L, 1);

  assert(sizeof(uv_fs_t) > 0);
  assert(_Alignof(uv_fs_t) > 0);
  storage = lua_newuserdatauv(L, sizeof(uv_fs_t), 0);
  assert((uintptr_t)storage % _Alignof(uv_fs_t) == 0);
  fs = (uv_fs_t *)storage;
  assert((void *)fs == storage);
  lua_pop(L, 1);

  assert(sizeof(uv_buf_t) > 0);
  assert(_Alignof(uv_buf_t) > 0);
  storage = lua_newuserdatauv(L, sizeof(uv_buf_t), 0);
  assert((uintptr_t)storage % _Alignof(uv_buf_t) == 0);
  buf = (uv_buf_t *)storage;
  assert((void *)buf == storage);
  lua_pop(L, 1);

  storage = lua_newuserdatauv(L, sizeof(uv_getaddrinfo_t), 0);
  assert((uintptr_t)storage % _Alignof(uv_getaddrinfo_t) == 0);
  dns = (uv_getaddrinfo_t *)storage;
  assert((void *)dns == storage);
  lua_pop(L, 1);

  storage = lua_newuserdatauv(L, sizeof(uv_connect_t), 0);
  assert((uintptr_t)storage % _Alignof(uv_connect_t) == 0);
  connect = (uv_connect_t *)storage;
  assert((void *)connect == storage);
  lua_pop(L, 1);

  storage = lua_newuserdatauv(L, sizeof(uv_write_t), 0);
  assert((uintptr_t)storage % _Alignof(uv_write_t) == 0);
  write = (uv_write_t *)storage;
  assert((void *)write == storage);
  lua_pop(L, 1);

  storage = lua_newuserdatauv(L, sizeof(uv_shutdown_t), 0);
  assert((uintptr_t)storage % _Alignof(uv_shutdown_t) == 0);
  shutdown = (uv_shutdown_t *)storage;
  assert((void *)shutdown == storage);
  lua_pop(L, 1);

  storage = lua_newuserdatauv(L, sizeof(uv_tcp_t), 0);
  assert((uintptr_t)storage % _Alignof(uv_tcp_t) == 0);
  tcp = (uv_tcp_t *)storage;
  assert((void *)tcp == storage);
  lua_pop(L, 1);

  storage = lua_newuserdatauv(L, sizeof(uv_signal_t), 0);
  assert((uintptr_t)storage % _Alignof(uv_signal_t) == 0);
  signal = (uv_signal_t *)storage;
  assert((void *)signal == storage);
  lua_pop(L, 1);

  storage = lua_newuserdatauv(L, sizeof(titan_uvshim_address), 0);
  assert((uintptr_t)storage % _Alignof(titan_uvshim_address) == 0);
  address = (titan_uvshim_address *)storage;
  assert((void *)address == storage);
  lua_pop(L, 1);
}

int main(int argc, char **argv) {
  lua_State *L;
  uv_loop_t loop;
  uv_timer_t timer;
  uv_fs_t fs_req;
  uv_getaddrinfo_t dns_req;
  uv_tcp_t tcp;
  uv_signal_t signal;
  struct sockaddr_in bind_address;
  titan_uvshim_address address;
  int module_ref;
  int dispatcher_ref;
  int pending_ref;
  int stack_top;
  Udata *timer_owner;
  Udata *fs_owner;
  Udata *dns_owner;
  Udata *tcp_owner;
  Udata *signal_owner;

  assert(uv_setup_args(argc, argv) != NULL);
  L = luaL_newstate();
  assert(L != NULL);
  assert(uv_loop_init(&loop) == 0);
  assert(titan_uvshim_loop_handle_count(&loop) == 0);
  assert(strcmp(titan_uvshim_loop_first_handle_type(&loop), "unknown") == 0);
  assert(titan_uvshim_status_is_ebusy(UV_EBUSY));
  assert(!titan_uvshim_status_is_ebusy(UV_EINVAL));
  assert(titan_uvshim_error_eio() == UV_EIO);
  assert(titan_uvshim_error_eof() == UV_EOF);
  assert(titan_uvshim_error_ecanceled() == UV_ECANCELED);
  assert(titan_uvshim_error_eaddrnotavail() == UV_EADDRNOTAVAIL);
  assert(titan_uvshim_tcp_close_reset(NULL) == UV_EINVAL);
  expected_L = L;
  test_slot_numbering();
  test_buffers();
  test_binary_helpers();
  test_os_helpers();
  test_signal_mapping();
  test_native_storage_layout(L);

  module_ref = registry_ref_for_new_udata(L, 0);
  lua_rawgeti(L, LUA_REGISTRYINDEX, module_ref);
  expected_module = uvalue(s2v(L->top.p - 1));
  lua_pop(L, 1);
  dispatcher_ref = make_dispatcher(L, module_ref);
  lua_newtable(L);
  pending_ref = luaL_ref(L, LUA_REGISTRYINDEX);

  assert(uv_timer_init(&loop, &timer) == 0);
  assert(titan_uvshim_loop_handle_count(&loop) == 1);
  assert(strcmp(titan_uvshim_loop_first_handle_type(&loop), "timer") == 0);
  expected_timer = &timer;
  timer_owner = push_owner(L, &timer, module_ref, dispatcher_ref);
  titan_uvshim_timer_set_data(&timer, timer_owner);
  assert(titan_uvshim_timer_get_data(&timer) == timer_owner);
  assert(uv_timer_start(&timer, titan_uvshim_timer_cb, 0, 0) == 0);
  pending_store_and_pop(L, pending_ref, 1);
  stack_top = lua_gettop(L);
  lua_gc(L, LUA_GCCOLLECT);
  assert(uv_run(&loop, UV_RUN_DEFAULT) == 0);
  assert(lua_gettop(L) == stack_top);
  assert(timer_dispatches == 1);
  assert(close_dispatches == 1);
  assert(lua_wrapper_calls == 0);
  pending_remove(L, pending_ref, 1);

  expected_signal = &signal;
  signal_owner = push_owner(L, &signal, module_ref, dispatcher_ref);
  assert(titan_uvshim_signal_init(&loop, &signal, signal_owner) == 0);
  assert(!titan_uvshim_signal_is_closing(&signal));
  assert(titan_uvshim_signal_start_oneshot(
             &signal, titan_uvshim_signal_number("kill")) == UV_EINVAL);
  assert(titan_uvshim_signal_start_oneshot(
             &signal, titan_uvshim_signal_number("usr1")) == 0);
  pending_store_and_pop(L, pending_ref, 5);
  stack_top = lua_gettop(L);
  lua_gc(L, LUA_GCCOLLECT);
  assert(uv_kill(uv_os_getpid(),
                 titan_uvshim_signal_number("usr1")) == 0);
  assert(uv_run(&loop, UV_RUN_DEFAULT) == 0);
  assert(lua_gettop(L) == stack_top);
  assert(signal_dispatches == 1);
  assert(signal_close_dispatches == 1);
  assert(lua_wrapper_calls == 0);
  pending_remove(L, pending_ref, 5);

  expected_fs = &fs_req;
  fs_owner = push_owner(L, &fs_req, module_ref, dispatcher_ref);
  titan_uvshim_fs_set_data(&fs_req, fs_owner);
  assert(titan_uvshim_fs_get_data(&fs_req) == fs_owner);
  assert(uv_fs_stat(&loop, &fs_req, ".", titan_uvshim_fs_cb) == 0);
  pending_store_and_pop(L, pending_ref, 2);

  expected_dns = &dns_req;
  dns_owner = push_owner(L, &dns_req, module_ref, dispatcher_ref);
  assert(titan_uvshim_getaddrinfo_start(
             &loop, &dns_req, dns_owner, "127.0.0.1", 80) == 0);
  pending_store_and_pop(L, pending_ref, 3);

  memset(&address, 0, sizeof(address));
  assert(uv_ip4_addr("127.0.0.1", 0, &bind_address) == 0);
  memcpy(address.bytes, &bind_address, sizeof(bind_address));
  expected_tcp = &tcp;
  tcp_owner = push_owner(L, &tcp, module_ref, dispatcher_ref);
  assert(titan_uvshim_tcp_init(&loop, &tcp, tcp_owner) == 0);
  assert(!titan_uvshim_tcp_is_closing(&tcp));
  assert(titan_uvshim_tcp_bind(&tcp, &address, 1, 0) == 0);
  assert(titan_uvshim_tcp_bound_port(&tcp) > 0);
  assert(titan_uvshim_tcp_listen_backlog_is_valid(1));
  assert(titan_uvshim_tcp_listen_backlog_is_valid(INT_MAX));
  assert(!titan_uvshim_tcp_listen_backlog_is_valid(0));
  assert(!titan_uvshim_tcp_listen_backlog_is_valid((int64_t)INT_MAX + 1));
  assert(titan_uvshim_tcp_listen(&tcp, (int64_t)INT_MAX + 1) == UV_EINVAL);
  assert(titan_uvshim_tcp_listen(&tcp, 8) == 0);
  titan_uvshim_tcp_close(&tcp);
  assert(titan_uvshim_tcp_is_closing(&tcp));
  pending_store_and_pop(L, pending_ref, 4);

  /* Owner fields, not independent registry references, root module/dispatch. */
  luaL_unref(L, LUA_REGISTRYINDEX, dispatcher_ref);
  luaL_unref(L, LUA_REGISTRYINDEX, module_ref);
  stack_top = lua_gettop(L);
  lua_gc(L, LUA_GCCOLLECT);
  assert(uv_run(&loop, UV_RUN_DEFAULT) == 0);
  assert(lua_gettop(L) == stack_top);
  assert(fs_dispatches == 1);
  assert(fs_cleanups == 1);
  assert(dns_dispatches == 1);
  assert(tcp_close_dispatches == 1);
  assert(lua_wrapper_calls == 0);
  pending_remove(L, pending_ref, 2);
  pending_remove(L, pending_ref, 3);
  pending_remove(L, pending_ref, 4);

  assert(uv_loop_close(&loop) == 0);
  luaL_unref(L, LUA_REGISTRYINDEX, pending_ref);
  lua_close(L);
  puts("libuv shim probe passed");
  return 0;
}
