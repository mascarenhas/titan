#ifndef TITAN_UV_TEST_ALLOCATION_H
#define TITAN_UV_TEST_ALLOCATION_H

#include <stddef.h>

/* Test-only internal-userdata counter selected by uv_native_handles_spec.lua. */
void titan_uv_test_reset_internal_userdata_allocations(void);
size_t titan_uv_test_get_internal_userdata_allocations(void);

#endif
