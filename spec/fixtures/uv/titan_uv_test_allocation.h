#ifndef TITAN_UV_TEST_ALLOCATION_H
#define TITAN_UV_TEST_ALLOCATION_H

#include <stddef.h>
#include <lua.h>

/* Test-only wrappers selected with compilation flags in uv_spec.lua. */
void *titan_uv_test_newuserdatauv(lua_State *L, size_t size, int uservalues);
void titan_uv_test_reset_userdata_allocations(void);
size_t titan_uv_test_get_userdata_allocations(void);
size_t titan_uv_test_get_internal_userdata_allocations(void);

/*
 * Advance an incremental cycle until both owners are black, then stop the
 * collector without ending the cycle.  The matching finish call restarts and
 * completes that same cycle.  These are deterministic test probes for Titan's
 * record-field barriers, not production runtime APIs.
 */
int titan_uv_test_gc_pause_when_black(lua_State *L, void *first,
                                      void *second);
int titan_uv_test_gc_finish_incremental(lua_State *L);

#endif
