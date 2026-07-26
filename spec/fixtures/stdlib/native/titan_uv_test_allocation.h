#ifndef TITAN_UV_TEST_ALLOCATION_H
#define TITAN_UV_TEST_ALLOCATION_H

#include <stddef.h>

/*
 * Keep the library-behavior fixture's native owner nominally tied to libuv
 * without importing libuv's complete public header into Titan. The C fixture
 * owns the complete definition and reports its exact storage size.
 */
struct uv_timer_s;
typedef struct uv_timer_s titan_uv_test_timer;
size_t titan_uv_test_timer_size(void);

/* Test-only counters selected by uv_native_handles_spec.lua. */
void titan_uv_test_reset_userdata_allocations(void);
size_t titan_uv_test_get_userdata_allocations(void);
size_t titan_uv_test_get_internal_userdata_allocations(void);

#endif
