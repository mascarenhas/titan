#include "lobject.h"
#include "lvm.h"

static int titan_coro_tag_equal(void *t1, void *t2);

#define MCO_NO_DEBUG
#define MCO_USE_VMEM_ALLOCATOR
#define MCO_TAG_COMPARATOR titan_coro_tag_equal
#define MINICORO_IMPL
#include "minicoro.h"

static int titan_coro_tag_equal(void *t1, void *t2) {
  return luaV_equalobj(NULL, (const TValue *)t1, (const TValue *)t2);
}
