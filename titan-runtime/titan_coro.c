#include "lobject.h"
#include "lua.h"
#include "lvm.h"

#define MCO_NO_DEBUG
#define MCO_USE_VMEM_ALLOCATOR
#define MINICORO_IMPL
#include "minicoro.h"
#include "titan/coro.h"
#include "titan/ffi.h"

int titan_coro_tag_equal(void *t1, void *t2) {
  return luaV_equalobj(NULL, (const TValue *)t1, (const TValue *)t2);
}

void titan_coro_entry(mco_coro *co) {
  Udata *ud = mco_get_user_data(co);
  lua_State *T = gco2th(ud->uv[0].uv.value_.gc);
  TValue coro_entry = ud->uv[2].uv;
  TValue f = ud->uv[3].uv;
  lua_pushtvalue(T, coro_entry);
  lua_pushtvalue(T, f);
  lua_pushlightuserdata(T, co);
  lua_call(T, 2, 0);
}
