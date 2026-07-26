#ifndef TITAN_CORO_H
#define TITAN_CORO_H

/*
 * Minimal forward declaration from minicoro.h to avoid importing the entire
 * header for the FFI.
 */
struct mco_coro;

void titan_coro_entry(struct mco_coro *co);
int titan_coro_tag_equal(void *t1, void *t2);

#endif
