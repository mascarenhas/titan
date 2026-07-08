#ifndef TITAN_CORO_H
#define TITAN_CORO_H

#include "ffi.h"

/*
** Private, unsafe FFI boundary for the standard coro.titan module.
** titan_coro_ref values are borrowed minicoro pointers from their owning
** coroutine handle or the currently running coroutine; Titan code must not
** store them or call these transfer primitives outside the wrapper protocol
** in coro.titan.
** titan_coro_handle assumes its argument is Coro.handle's userdata; passing
** any other value is undefined behavior.
*/
typedef struct mco_coro *titan_coro_ref;

TValue titan_coro_create(lua_State *L, TValue func);
titan_coro_ref titan_coro_handle(TValue handle);

#endif
