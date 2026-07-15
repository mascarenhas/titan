#include "lobject.h"
#include "lvm.h"
#include "titan/coro.h"

#define MCO_NO_DEBUG
#define MCO_USE_VMEM_ALLOCATOR
#define MCO_TAG_COMPARATOR titan_coro_tag_equal
#define MINICORO_IMPL
#include "minicoro.h"

int titan_coro_tag_equal(void *t1, void *t2) {
  return luaV_equalobj(NULL, (const TValue *)t1, (const TValue *)t2);
}

typedef void (*titan_coro_entry_func)(lua_State *L, Udata *_mod,
                                      CClosure *_fn, TValue _param_func,
                                      mco_coro *_param_co);

void titan_coro_entry(mco_coro *co) {
  Udata *ud = mco_get_user_data(co);
  lua_State *T = thvalue(&ud->uv[0].uv);
  Udata *M = uvalue(&ud->uv[1].uv);
  CClosure *coro_entry = clCvalue(&ud->uv[2].uv);
  TValue f = ud->uv[3].uv;
  titan_coro_entry_func coro_entry_f = pvalue(&coro_entry->upvalue[2]);
  coro_entry_f(T, M, NULL, f, co);
}
