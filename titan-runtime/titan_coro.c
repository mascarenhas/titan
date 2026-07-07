#include <stdint.h>
#include <string.h>

#include "lua.h"
#include "lauxlib.h"
#include "lstate.h"
#include "lobject.h"
#include "ldo.h"
#include "lvm.h"
#include "titan.h"
#include "titan/coro.h"

#define MINICORO_IMPL
#include "minicoro.h"

#define TITAN_CORO_MAGIC 0x54434f52u
#define TITAN_CORO_UV_THREAD  1
#define TITAN_CORO_UV_FUNC    2
#define TITAN_CORO_UV_PAYLOAD 3
#define TITAN_CORO_UV_TRACE   4
#define TITAN_CORO_NUV        4
#define TITAN_CORO_STACK_SIZE (1024 * 1024)

typedef struct titan_coro {
  uint32_t magic;
  mco_coro *co;
  lua_State *thread;
  TValue self;
  int transfer_ok;
} titan_coro;

static char titan_coro_live_key;

static void titan_coro_push_tvalue(lua_State *L, const TValue *v) {
  lua_checkstack(L, 1);
  setobj2s(L, L->top.p, v);
  L->top.p++;
}

static void titan_coro_get_live_table(lua_State *L) {
  lua_rawgetp(L, LUA_REGISTRYINDEX, &titan_coro_live_key);
  if(lua_isnil(L, -1)) {
    lua_pop(L, 1);
    lua_newtable(L);
    lua_pushvalue(L, -1);
    lua_rawsetp(L, LUA_REGISTRYINDEX, &titan_coro_live_key);
  }
}

static void titan_coro_live_set(lua_State *L, titan_coro *tc, int live) {
  int top = lua_gettop(L);
  titan_coro_get_live_table(L);
  titan_coro_push_tvalue(L, &tc->self);
  if(live) {
    lua_pushboolean(L, 1);
  } else {
    lua_pushnil(L);
  }
  lua_rawset(L, -3);
  lua_settop(L, top);
}

static void titan_coro_set_uv(lua_State *L, titan_coro *tc, int slot,
                              const TValue *value) {
  int top = lua_gettop(L);
  titan_coro_push_tvalue(L, &tc->self);
  titan_coro_push_tvalue(L, value);
  lua_setiuservalue(L, -2, slot);
  lua_settop(L, top);
}

static TValue titan_coro_get_uv(lua_State *L, titan_coro *tc, int slot) {
  TValue value;
  int top = lua_gettop(L);
  titan_coro_push_tvalue(L, &tc->self);
  lua_getiuservalue(L, -1, slot);
  value = *s2v(L->top.p - 1);
  lua_settop(L, top);
  return value;
}

static titan_coro *titan_coro_from_value(TValue handle) {
  Udata *ud;
  titan_coro *tc;
  if(!ttisfulluserdata(&handle)) {
    return NULL;
  }
  ud = uvalue(&handle);
  tc = (titan_coro *)getudatamem(ud);
  if(!tc || tc->magic != TITAN_CORO_MAGIC) {
    return NULL;
  }
  return tc;
}

static titan_coro *titan_coro_from_mco(mco_coro *co) {
  return co ? (titan_coro *)mco_get_user_data(co) : NULL;
}

static titan_coro *titan_coro_current(void) {
  return titan_coro_from_mco(mco_running());
}

static titan_coro *titan_coro_transfer_source(titan_coro *tc) {
  while(tc && tc->co && tc->co->stacked_child) {
    tc = titan_coro_from_mco(tc->co->stacked_child);
  }
  return tc;
}

static titan_coro *titan_coro_transfer_target(titan_coro *tc) {
  return titan_coro_transfer_source(tc);
}

static int titan_coro_tag_equal(void *t1, void *t2) {
  return luaV_equalobj(NULL, (const TValue *)t1, (const TValue *)t2);
}

static void titan_coro_save_trace(lua_State *L, titan_coro *tc) {
  int top = lua_gettop(L);
  lua_getfield(L, LUA_REGISTRYINDEX, TITAN_BACKTRACE_KEY);
  if(!lua_isnil(L, -1)) {
    TValue trace = *s2v(L->top.p - 1);
    titan_coro_set_uv(L, tc, TITAN_CORO_UV_TRACE, &trace);
  }
  lua_settop(L, top);
}

static void titan_coro_restore_trace(lua_State *L, titan_coro *tc) {
  TValue trace = titan_coro_get_uv(L, tc, TITAN_CORO_UV_TRACE);
  if(!ttisnil(&trace)) {
    titan_coro_push_tvalue(L, &trace);
    lua_setfield(L, LUA_REGISTRYINDEX, TITAN_BACKTRACE_KEY);
    lua_pushboolean(L, 1);
    lua_setfield(L, LUA_REGISTRYINDEX, TITAN_TRACE_PINNED);
  }
}

static int titan_coro_gc(lua_State *L) {
  titan_coro *tc = (titan_coro *)lua_touserdata(L, 1);
  if(tc && tc->magic == TITAN_CORO_MAGIC) {
    tc->magic = 0;
    if(tc->co) {
      mco_destroy(tc->co);
      tc->co = NULL;
    }
  }
  return 0;
}

static void titan_coro_ensure_metatable(lua_State *L) {
  if(luaL_newmetatable(L, "titan.coro")) {
    lua_pushcfunction(L, titan_coro_gc);
    lua_setfield(L, -2, "__gc");
  }
  lua_pop(L, 1);
}

static void titan_coro_entry(mco_coro *co) {
  titan_coro *tc = titan_coro_from_mco(co);
  lua_State *T = tc->thread;
  int top = lua_gettop(T);
  int status;
  TValue func;
  TValue arg;
  TValue payload;

  if(!tc->transfer_ok) {
    payload = titan_coro_get_uv(T, tc, TITAN_CORO_UV_PAYLOAD);
    titan_coro_set_uv(T, tc, TITAN_CORO_UV_PAYLOAD, &payload);
    titan_coro_live_set(T, tc, 0);
    lua_settop(T, top);
    return;
  }

  lua_pushcfunction(T, errorhandler);
  func = titan_coro_get_uv(T, tc, TITAN_CORO_UV_FUNC);
  arg = titan_coro_get_uv(T, tc, TITAN_CORO_UV_PAYLOAD);
  titan_coro_push_tvalue(T, &func);
  titan_coro_push_tvalue(T, &arg);
  status = lua_pcall(T, 1, 1, top + 1);
  payload = *s2v(T->top.p - 1);
  if(status == LUA_OK) {
    tc->transfer_ok = 1;
  } else {
    tc->transfer_ok = 0;
    titan_coro_save_trace(T, tc);
  }
  titan_coro_set_uv(T, tc, TITAN_CORO_UV_PAYLOAD, &payload);
  titan_coro_live_set(T, tc, 0);
  lua_settop(T, top);
}

TValue titan_coro_create(lua_State *L, TValue func) {
  int top = lua_gettop(L);
  TValue result;
  titan_coro *tc;
  mco_desc desc;
  mco_result res;

  titan_coro_ensure_metatable(L);
  tc = (titan_coro *)lua_newuserdatauv(L, sizeof(titan_coro), TITAN_CORO_NUV);
  memset(tc, 0, sizeof(*tc));
  tc->magic = TITAN_CORO_MAGIC;
  tc->transfer_ok = 1;
  tc->self = *s2v(L->top.p - 1);
  luaL_getmetatable(L, "titan.coro");
  lua_setmetatable(L, -2);

  lua_newthread(L);
  tc->thread = lua_tothread(L, -1);
  lua_setiuservalue(L, -2, TITAN_CORO_UV_THREAD);
  titan_coro_push_tvalue(L, &func);
  lua_setiuservalue(L, -2, TITAN_CORO_UV_FUNC);
  lua_pushnil(L);
  lua_setiuservalue(L, -2, TITAN_CORO_UV_PAYLOAD);
  lua_pushnil(L);
  lua_setiuservalue(L, -2, TITAN_CORO_UV_TRACE);

  desc = mco_desc_init(titan_coro_entry, TITAN_CORO_STACK_SIZE);
  desc.user_data = tc;
  res = mco_create(&tc->co, &desc);
  if(res != MCO_SUCCESS) {
    luaL_error(L, "could not create coroutine: %s", mco_result_description(res));
  }
  titan_coro_live_set(L, tc, 1);
  result = tc->self;
  lua_settop(L, top);
  return result;
}

int titan_coro_push(lua_State *L, TValue handle, int ok, TValue payload) {
  titan_coro *tc = titan_coro_transfer_target(titan_coro_from_value(handle));
  if(!tc) return MCO_INVALID_COROUTINE;
  tc->transfer_ok = ok;
  titan_coro_set_uv(L, tc, TITAN_CORO_UV_PAYLOAD, &payload);
  return MCO_SUCCESS;
}

int titan_coro_push_current(lua_State *L, int ok, TValue payload) {
  titan_coro *tc = titan_coro_current();
  if(!tc) return MCO_INVALID_COROUTINE;
  tc->transfer_ok = ok;
  titan_coro_set_uv(L, tc, TITAN_CORO_UV_PAYLOAD, &payload);
  return MCO_SUCCESS;
}

int titan_coro_resume(lua_State *L, TValue handle, TValue tag) {
  titan_coro *tc = titan_coro_from_value(handle);
  mco_result res;
  if(!tc) return MCO_INVALID_COROUTINE;
  res = mco_resume_tagged(tc->co, &tag, titan_coro_tag_equal);
  if(res == MCO_SUCCESS) {
    titan_coro *source = titan_coro_transfer_source(tc);
    if(source && !source->transfer_ok) {
      titan_coro_restore_trace(L, source);
    }
  }
  return res;
}

int titan_coro_yield(lua_State *L, TValue tag) {
  titan_coro *tc = titan_coro_current();
  (void)L;
  if(!tc) return MCO_INVALID_COROUTINE;
  return mco_yield_tagged(tc->co, &tag, titan_coro_tag_equal);
}

int titan_coro_pop_ok(lua_State *L, TValue handle) {
  titan_coro *tc = titan_coro_transfer_source(titan_coro_from_value(handle));
  (void)L;
  return tc ? tc->transfer_ok : 0;
}

TValue titan_coro_pop_payload(lua_State *L, TValue handle) {
  titan_coro *tc = titan_coro_transfer_source(titan_coro_from_value(handle));
  TValue nilv;
  setnilvalue(&nilv);
  return tc ? titan_coro_get_uv(L, tc, TITAN_CORO_UV_PAYLOAD) : nilv;
}

int titan_coro_pop_current_ok(lua_State *L) {
  titan_coro *tc = titan_coro_current();
  (void)L;
  return tc ? tc->transfer_ok : 0;
}

TValue titan_coro_pop_current_payload(lua_State *L) {
  titan_coro *tc = titan_coro_current();
  TValue nilv;
  setnilvalue(&nilv);
  return tc ? titan_coro_get_uv(L, tc, TITAN_CORO_UV_PAYLOAD) : nilv;
}

int titan_coro_is_yieldable(lua_State *L, TValue tag) {
  titan_coro *tc = titan_coro_current();
  (void)L;
  return tc && mco_is_yieldable_tagged(tc->co, &tag, titan_coro_tag_equal);
}

int titan_coro_status(lua_State *L, TValue handle) {
  titan_coro *tc = titan_coro_from_value(handle);
  (void)L;
  if(!tc || !tc->co) return TITAN_CORO_STATUS_DEAD;
  switch(mco_status(tc->co)) {
    case MCO_SUSPENDED: return TITAN_CORO_STATUS_SUSPENDED;
    case MCO_RUNNING: return TITAN_CORO_STATUS_RUNNING;
    case MCO_NORMAL: return TITAN_CORO_STATUS_NORMAL;
    case MCO_STACKED: return TITAN_CORO_STATUS_STACKED;
    case MCO_DEAD: return TITAN_CORO_STATUS_DEAD;
  }
  return TITAN_CORO_STATUS_DEAD;
}

char *titan_coro_result_name(int result) {
  return (char *)mco_result_description((mco_result)result);
}
