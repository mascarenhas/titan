#include "titan_uv_test_allocation.h"

#include "lgc.h"
#include "lobject.h"
#include "lstate.h"
#include "lstring.h"

static size_t titan_uv_test_userdata_allocations;
static size_t titan_uv_test_internal_userdata_allocations;

void *titan_uv_test_newuserdatauv(lua_State *L, size_t size, int uservalues) {
  titan_uv_test_userdata_allocations++;
  return lua_newuserdatauv(L, size, uservalues);
}

Udata *titan_uv_test_newudata(lua_State *L, size_t size,
                              unsigned short uservalues) {
  titan_uv_test_internal_userdata_allocations++;
  return luaS_newudata(L, size, uservalues);
}

void titan_uv_test_reset_userdata_allocations(void) {
  titan_uv_test_userdata_allocations = 0;
  titan_uv_test_internal_userdata_allocations = 0;
}

size_t titan_uv_test_get_userdata_allocations(void) {
  return titan_uv_test_userdata_allocations;
}

size_t titan_uv_test_get_internal_userdata_allocations(void) {
  return titan_uv_test_internal_userdata_allocations;
}

int titan_uv_test_gc_pause_when_black(lua_State *L, void *first,
                                      void *second) {
  GCObject *first_owner = cast(GCObject *, first);
  GCObject *second_owner = cast(GCObject *, second);
  global_State *g = G(L);

  lua_gc(L, LUA_GCINC);
  lua_gc(L, LUA_GCRESTART);
  luaC_runtilstate(L, GCSpropagate, 0);
  luaC_runtilstate(L, GCSenteratomic, 0);
  lua_gc(L, LUA_GCSTOP);
  return keepinvariant(g) && isblack(first_owner) && isblack(second_owner);
}

int titan_uv_test_gc_finish_incremental(lua_State *L) {
  global_State *g = G(L);

  lua_gc(L, LUA_GCRESTART);
  luaC_runtilstate(L, GCSpause, 0);
  return g->gcstate == GCSpause;
}
