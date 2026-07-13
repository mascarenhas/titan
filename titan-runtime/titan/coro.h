#ifndef TITAN_CORO_H
#define TITAN_CORO_H

/*
 * Minimal forward declarations from lua.h and minicoro.h
 * to avoid importing the entire headers for the FFI
 */
typedef struct TValue TValue;
typedef struct mco_coro mco_coro;

#define TITAN_CORO_ENTRY_FUNCTION "b2aef939-2a2f-4e6c-b880-a01bc9cc07c2"

void titan_coro_entry(mco_coro *co);
int titan_coro_tag_equal(void *t1, void *t2);

#endif
