#include "lgc.h"
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

/*
 * Minicoro copies transfer payload bytes but does not trace their Lua object.
 * Keep the one pending transfer in the source coroutine owner's fifth
 * uservalue until the receiver has copied it into a scanned Lua stack slot.
 */
void titan_coro_root_transfer(lua_State *L, mco_coro *co, TValue payload) {
  if (co == NULL)
    return;
  Udata *ud = mco_get_user_data(co);
  lua_assert(ud != NULL && ud->nuvalue == TITAN_CORO_OWNER_USERVALUES);
  setobj(L, &ud->uv[4].uv, &payload);
  luaC_barrierback(L, obj2gco(ud), &ud->uv[4].uv);
}

void titan_coro_clear_transfer(mco_coro *co) {
  if (co == NULL)
    return;
  Udata *ud = mco_get_user_data(co);
  lua_assert(ud != NULL && ud->nuvalue == TITAN_CORO_OWNER_USERVALUES);
  setnilvalue(&ud->uv[4].uv);
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
