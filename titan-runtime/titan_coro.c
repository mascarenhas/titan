#include "lobject.h"
#include "lua.h"
#include "lvm.h"

#define MCO_NO_DEBUG
#define MCO_USE_VMEM_ALLOCATOR
#define MINICORO_IMPL
#include "minicoro.h"
#include "titan/coro.h"

int titan_coro_tag_equal(void *t1, void *t2) {
  return luaV_equalobj(NULL, (const TValue *)t1, (const TValue *)t2);
}

void titan_coro_entry(mco_coro *co) {
  lua_State *T = mco_get_user_data(co);
  lua_getfield(T, LUA_REGISTRYINDEX, TITAN_CORO_ENTRY_FUNCTION);
  lua_pushlightuserdata(T, co);
  lua_call(T, 1, 0);
}
