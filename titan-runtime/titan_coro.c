#include "lobject.h"
#include "lua.h"
#include "lvm.h"
#include "titan/coro.h"

#define MCO_NO_DEBUG
#define MCO_USE_VMEM_ALLOCATOR
#define MCO_TAG_COMPARATOR titan_coro_tag_equal
#define MINICORO_IMPL
#include "minicoro.h"
#include "titan/ffi.h"

#define TITAN_CORO_RUNTIME_KEY "Titan coroutine runtime 0.11"

static mco_runtime *titan_coro_runtime(lua_State *L) {
  int top = lua_gettop(L);
  mco_runtime *runtime;

  lua_getfield(L, LUA_REGISTRYINDEX, TITAN_CORO_RUNTIME_KEY);
  if (lua_type(L, -1) == LUA_TUSERDATA &&
      lua_rawlen(L, -1) == sizeof(mco_runtime)) {
    runtime = (mco_runtime *)lua_touserdata(L, -1);
    lua_settop(L, top);
    return runtime;
  }

  lua_settop(L, top);
  runtime = (mco_runtime *)lua_newuserdatauv(L, sizeof(mco_runtime), 0);
  memset(runtime, 0, sizeof(mco_runtime));
  lua_setfield(L, LUA_REGISTRYINDEX, TITAN_CORO_RUNTIME_KEY);
  return runtime;
}

void titan_coro_configure(lua_State *L, mco_desc *desc) {
  desc->runtime = titan_coro_runtime(L);
}

mco_coro *titan_coro_running(lua_State *L) {
  return titan_coro_runtime(L)->current_co;
}

int titan_coro_tag_equal(void *t1, void *t2) {
  return luaV_equalobj(NULL, (const TValue *)t1, (const TValue *)t2);
}

typedef void (*titan_coro_entry_func)(lua_State *L, Udata *_mod,
                                      CClosure *_fn, TValue _param_func,
                                      mco_coro *_param_co);

void titan_coro_entry(mco_coro *co) {
  Udata *ud = mco_get_user_data(co);
  lua_State *T = thvalue(&ud->uv[0].uv);
  Udata *M = uvalue(&ud->uv[1].uv);
  CClosure *coro_entry = clCvalue(&ud->uv[2].uv);
  TValue f = ud->uv[3].uv;
  titan_coro_entry_func coro_entry_f = pvalue(&coro_entry->upvalue[2]);
  coro_entry_f(T, M, NULL, f, co);
}
