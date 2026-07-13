#ifndef TITAN_CORO_H
#define TITAN_CORO_H

/*
 * Minimal forward declarations from lua.h and minicoro.h
 * to avoid importing the entire headers for the FFI
 */
typedef struct TValue TValue;
typedef struct lua_State lua_State;
typedef struct mco_coro mco_coro;
typedef struct mco_desc mco_desc;

#define TITAN_CORO_ENTRY_FUNCTION "b2aef939-2a2f-4e6c-b880-a01bc9cc07c2"

void titan_coro_entry(mco_coro *co);
int titan_coro_tag_equal(void *t1, void *t2);
void titan_coro_configure(lua_State *L, mco_desc *desc);
mco_coro *titan_coro_running(lua_State *L);

#endif
