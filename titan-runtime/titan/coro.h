#ifndef TITAN_CORO_H
#define TITAN_CORO_H

#include "ffi.h"

/*
** Private, unsafe FFI boundary for the standard coro.titan module.
** titan_coro_ref values are borrowed minicoro pointers from their owning
** coroutine handle or the currently running coroutine; Titan code must not
** store them or call these transfer primitives outside the wrapper protocol
** in coro.titan.
*/
typedef struct mco_coro *titan_coro_ref;

TValue titan_coro_create(lua_State *L, TValue func);
titan_coro_ref titan_coro_handle(TValue handle);
void titan_coro_clear_dead(lua_State *L, titan_coro_ref source);
void titan_coro_raise(lua_State *L, titan_coro_ref source, TValue payload);

#endif
