#include "lua.h"
#include "lauxlib.h"
#include "lstate.h"
#include "lobject.h"
#include "lgc.h"
#include "ldo.h"
#include "lvm.h"
#include "titan.h"

#define MCO_NO_DEBUG
#define MCO_USE_VMEM_ALLOCATOR
#define MINICORO_IMPL
#include "minicoro.h"
#include "titan/coro.h"

#define TITAN_CORO_UV_THREAD  1
#define TITAN_CORO_NUV        1
#define TITAN_CORO_STACK_SIZE (2 * 1024 * 1024)

static inline TValue *titan_coro_uv(Udata *ud, int slot) {
  return &ud->uv[slot - 1].uv;
}

static inline void titan_coro_set_ud_uv(lua_State *L, Udata *ud, int slot,
                                        const TValue *value) {
  TValue *uv = titan_coro_uv(ud, slot);
  setobj(L, uv, value);
  luaC_barrierback(L, obj2gco(ud), uv);
}

static inline lua_State *titan_coro_thread_from_mco(mco_coro *co) {
  return co ? (lua_State *)mco_get_user_data(co) : NULL;
}

static inline StkId titan_coro_func_slot(lua_State *L) {
  return L->stack.p + 1;
}

static int titan_coro_tag_equal(void *t1, void *t2) {
  return luaV_equalobj(NULL, (const TValue *)t1, (const TValue *)t2);
}

static inline int titan_coro_push_transfer(mco_coro *co, int ok,
                                           TValue payload) {
  mco_result res = mco_push(co, &payload, sizeof(payload));
  if(res != MCO_SUCCESS) {
    return res;
  }
  res = mco_push(co, &ok, sizeof(ok));
  if(res != MCO_SUCCESS) {
    TValue ignored;
    (void)mco_pop(co, &ignored, sizeof(ignored));
  }
  return res;
}

static inline int titan_coro_pop_transfer(mco_coro *co, int *ok,
                                          TValue *payload) {
  mco_result res = mco_pop(co, ok, sizeof(*ok));
  if(res != MCO_SUCCESS) {
    return res;
  }
  return mco_pop(co, payload, sizeof(*payload));
}

typedef struct titan_coro_call {
  ptrdiff_t func;
} titan_coro_call;

static void titan_coro_call_noyield(lua_State *L, void *ud) {
  titan_coro_call *call = (titan_coro_call *)ud;
  luaD_callnoyield(L, restorestack(L, call->func), 1);
}

static int titan_coro_call_value(lua_State *L, TValue arg, TValue *result) {
  TValue func = *s2v(titan_coro_func_slot(L));
  ptrdiff_t old_errfunc = L->errfunc;
  CallInfo *old_ci = L->ci;
  lu_byte old_allowhook = L->allowhook;
  ptrdiff_t errfunc;
  ptrdiff_t funcslot;
  titan_coro_call call;
  TStatus status;
  StkId errslot;
  StkId resultslot;
  StkId top;

  lua_checkstack(L, 3);
  lua_pushcfunction(L, errorhandler);
  errfunc = savestack(L, L->top.p - 1);
  L->errfunc = errfunc;

  funcslot = savestack(L, L->top.p);
  top = L->top.p;
  setobj2s(L, top, &func);
  setobj2s(L, top + 1, &arg);
  L->top.p = top + 2;

  call.func = funcslot;
  status = luaD_rawrunprotected(L, titan_coro_call_noyield, &call);
  if(status != LUA_OK) {
    L->ci = old_ci;
    L->allowhook = old_allowhook;
    status = luaD_closeprotected(L, funcslot, status);
    luaD_seterrorobj(L, status, restorestack(L, funcslot));
    luaD_shrinkstack(L);
  }
  L->errfunc = old_errfunc;

  errslot = restorestack(L, errfunc);
  resultslot = restorestack(L, funcslot);
  setobjs2s(L, errslot, resultslot);
  L->top.p = errslot + 1;
  *result = *s2v(errslot);
  return status;
}

static void titan_coro_pin_trace(lua_State *L) {
  if(lua_getfield(L, LUA_REGISTRYINDEX, TITAN_BACKTRACE_KEY) == LUA_TNIL) {
    lua_pop(L, 1);
  } else {
    lua_pop(L, 1);
    lua_pushboolean(L, 1);
    lua_setfield(L, LUA_REGISTRYINDEX, TITAN_TRACE_PINNED);
  }
}

static inline void titan_coro_clear_dead_thread(lua_State *T) {
  T->top.p = titan_coro_func_slot(T);
}

static inline void titan_coro_finish(mco_coro *co, lua_State *T, int ok,
                                     TValue payload) {
  (void)titan_coro_push_transfer(co, ok, payload);
  titan_coro_clear_dead_thread(T);
}

static int titan_coro_gc(lua_State *L) {
  mco_coro **slot = (mco_coro **)lua_touserdata(L, 1);
  if(slot && *slot) {
    mco_coro *co = *slot;
    if(mco_destroy(co) == MCO_SUCCESS) {
      *slot = NULL;
    }
  }
  return 0;
}

static Table *titan_coro_ensure_metatable(lua_State *L) {
  Table *metatable;
  if(luaL_newmetatable(L, "titan.coro")) {
    lua_pushcfunction(L, titan_coro_gc);
    lua_setfield(L, -2, "__gc");
  }
  metatable = hvalue(s2v(L->top.p - 1));
  lua_pop(L, 1);
  return metatable;
}

static void titan_coro_entry(mco_coro *co) {
  lua_State *T = titan_coro_thread_from_mco(co);
  int status;
  int ok;
  TValue payload;

  if(!T) {
    return;
  }

  if(titan_coro_pop_transfer(co, &ok, &payload) != MCO_SUCCESS) {
    setnilvalue(&payload);
    titan_coro_finish(co, T, 0, payload);
    return;
  }

  if(!ok) {
    titan_coro_finish(co, T, 0, payload);
    return;
  }

  status = titan_coro_call_value(T, payload, &payload);
  if(status == LUA_OK) {
    ok = 1;
  } else {
    ok = 0;
    titan_coro_pin_trace(T);
  }
  titan_coro_finish(co, T, ok, payload);
}

TValue titan_coro_create(lua_State *L, TValue func) {
  int top = lua_gettop(L);
  Udata *ud;
  mco_coro **slot;
  lua_State *thread;
  TValue threadv;
  TValue result;
  mco_desc desc;
  mco_result res;
  Table *metatable;

  metatable = titan_coro_ensure_metatable(L);
  lua_newuserdatauv(L, sizeof(mco_coro *), TITAN_CORO_NUV);
  ud = uvalue(s2v(L->top.p - 1));
  slot = (mco_coro **)getudatamem(ud);
  *slot = NULL;
  ud->metatable = metatable;
  luaC_objbarrier(L, ud, metatable);

  lua_newthread(L);
  thread = lua_tothread(L, -1);
  threadv = *s2v(L->top.p - 1);
  titan_coro_set_ud_uv(L, ud, TITAN_CORO_UV_THREAD, &threadv);
  lua_pop(L, 1);

  lua_checkstack(thread, 1);
  setobj2s(thread, thread->top.p, &func);
  thread->top.p++;

  mco_set_tag_comparator(titan_coro_tag_equal);
  desc = mco_desc_init(titan_coro_entry, TITAN_CORO_STACK_SIZE);
  desc.user_data = thread;
  res = mco_create(slot, &desc);
  if(res != MCO_SUCCESS) {
    *slot = NULL;
    luaL_error(L, "could not create coroutine: %s", mco_result_description(res));
  }
  result = *s2v(L->top.p - 1);
  lua_settop(L, top);
  return result;
}

titan_coro_ref titan_coro_handle(TValue handle) {
  return *(mco_coro **)getudatamem(uvalue(&handle));
}
