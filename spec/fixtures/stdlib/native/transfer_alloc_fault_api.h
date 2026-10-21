#ifndef TITAN_TRANSFER_ALLOC_FAULT_API_H
#define TITAN_TRANSFER_ALLOC_FAULT_API_H

#include <stddef.h>
#include "lua.h"

typedef struct titan_transfer_fault_resource {
  size_t references;
  size_t retains;
  size_t releases;
  int invalid_release;
} titan_transfer_fault_resource;

/* This fixture runs in one fresh, synchronous, archive-linked child. Modes:
 * 1 first heap spill after the inline resources, 2 first spill growth,
 * 3 packet payload malloc, 4 structural buffer initialization,
 * 5 structural buffer growth, 6 endpoint finalizer registration.
 * Spill sizes derive from the provider's TITAN_TRANSFER_INLINE_RESOURCES. */
size_t titan_transfer_fault_inline_resources(void);
int titan_transfer_fault_watch_finalizer(lua_State *state, int index);
int titan_transfer_fault_install(lua_State *state);
void titan_transfer_fault_restore(lua_State *state);
titan_transfer_fault_resource *titan_transfer_fault_resource_at(unsigned int index);
void titan_transfer_fault_retain(void *resource);
void titan_transfer_fault_release(void *resource);
void titan_transfer_fault_arm(int mode);
void titan_transfer_fault_disarm(void);
int titan_transfer_fault_fired(void);
int titan_transfer_fault_allocator(void);
size_t titan_transfer_fault_retains_at_failure(void);
size_t titan_transfer_fault_releases_at_failure(void);

#endif
