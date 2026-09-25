#ifndef TITAN_SPEC_NOMINAL_ALLOCATION_PROBE_H
#define TITAN_SPEC_NOMINAL_ALLOCATION_PROBE_H

#include "lua.h"

/* Count fresh userdata requests from one isolated operation after module
 * initialization. Lua supplies the object tag as osize for a fresh allocation.
 * The probe delegates all allocation policy to the original allocator. */
static lua_Alloc nominal_probe_allocator;
static void *nominal_probe_data;
static size_t nominal_probe_count;
static size_t nominal_probe_bytes;

static void *nominal_probe_alloc(void *ud, void *ptr, size_t oldsize,
                                size_t newsize) {
  (void)ud;
  if (ptr == NULL && oldsize == LUA_TUSERDATA) {
    nominal_probe_count++;
    nominal_probe_bytes += newsize;
  }
  return nominal_probe_allocator(nominal_probe_data, ptr, oldsize, newsize);
}

static void nominal_probe_begin(lua_State *L) {
  nominal_probe_allocator = lua_getallocf(L, &nominal_probe_data);
  nominal_probe_count = 0;
  nominal_probe_bytes = 0;
  lua_setallocf(L, nominal_probe_alloc, NULL);
}

static size_t nominal_probe_end(lua_State *L) {
  lua_setallocf(L, nominal_probe_allocator, nominal_probe_data);
  return nominal_probe_count;
}

static size_t nominal_probe_size(void) { return nominal_probe_bytes; }

#endif
