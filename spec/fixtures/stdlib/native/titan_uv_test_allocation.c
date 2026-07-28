#include "lua.h"
#include "titan_uv_test_allocation.h"

#include "lobject.h"
#include "lstring.h"

static size_t titan_uv_test_internal_userdata_allocations;

Udata *titan_uv_test_newudata(lua_State *L, size_t size,
                              unsigned short uservalues) {
  titan_uv_test_internal_userdata_allocations++;
  return luaS_newudata(L, size, uservalues);
}

void titan_uv_test_reset_internal_userdata_allocations(void) {
  titan_uv_test_internal_userdata_allocations = 0;
}

size_t titan_uv_test_get_internal_userdata_allocations(void) {
  return titan_uv_test_internal_userdata_allocations;
}
