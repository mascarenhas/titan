#ifndef TITAN_UV_TEST_ALLOCATION_H
#define TITAN_UV_TEST_ALLOCATION_H

#include <stddef.h>
#include <lua.h>

/* Test-only wrappers selected with compilation flags in uv_spec.lua. */
void *titan_uv_test_newuserdatauv(lua_State *L, size_t size, int uservalues);
void titan_uv_test_reset_userdata_allocations(void);
size_t titan_uv_test_get_userdata_allocations(void);
size_t titan_uv_test_get_internal_userdata_allocations(void);

#endif
