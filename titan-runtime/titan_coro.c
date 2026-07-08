#include <stdlib.h>

#include "lua.h"
#include "lauxlib.h"
#include "lstate.h"
#include "lobject.h"
#include "lgc.h"
#include "ldo.h"
#include "lvm.h"
#include "titan.h"
#include "titan/coro.h"

#define MCO_NO_DEBUG
#define MCO_USE_VMEM_ALLOCATOR
#define MINICORO_IMPL
#include "minicoro.h"

#define TITAN_CORO_UV_THREAD  1
#define TITAN_CORO_UV_FUNC    2
#define TITAN_CORO_UV_TRACE   3
#define TITAN_CORO_NUV        3
#define TITAN_CORO_STACK_SIZE (2 * 1024 * 1024)

typedef struct titan_coro_data {
  Udata *handle;
  lua_State *thread;
} titan_coro_data;

static void titan_coro_push_tvalue(lua_State *L, const TValue *v) {
  lua_checkstack(L, 1);
  setobj2s(L, L->top.p, v);
  L->top.p++;
}

static TValue *titan_coro_uv(Udata *ud, int slot) {
  return &ud->uv[slot - 1].uv;
}

static void titan_coro_set_ud_uv(lua_State *L, Udata *ud, int slot,
                                 const TValue *value) {
  TValue *uv = titan_coro_uv(ud, slot);
  setobj(L, uv, value);
  luaC_barrierback(L, obj2gco(ud), uv);
}

static void titan_coro_clear_ud_uv(Udata *ud, int slot) {
  setnilvalue(titan_coro_uv(ud, slot));
}

static void titan_coro_set_uv(lua_State *L, titan_coro_data *data, int slot,
                              const TValue *value) {
  titan_coro_set_ud_uv(L, data->handle, slot, value);
}

static void titan_coro_clear_uv(lua_State *L, titan_coro_data *data,
                                int slot) {
  (void)L;
  titan_coro_clear_ud_uv(data->handle, slot);
}

static TValue titan_coro_get_uv(titan_coro_data *data, int slot) {
  return *titan_coro_uv(data->handle, slot);
}

static Table *titan_coro_ensure_metatable(lua_State *L);

static mco_coro *titan_coro_co_from_udata(lua_State *L, Udata *ud) {
  Table *metatable = titan_coro_ensure_metatable(L);
  if(!ud || ud->metatable != metatable ||
     ud->nuvalue != TITAN_CORO_NUV || ud->len != sizeof(mco_coro *)) {
    return NULL;
  }
  return *(mco_coro **)getudatamem(ud);
}

static mco_coro *titan_coro_co_from_value(lua_State *L, TValue handle) {
  if(!ttisfulluserdata(&handle)) {
    return NULL;
  }
  return titan_coro_co_from_udata(L, uvalue(&handle));
}

static titan_coro_data *titan_coro_data_from_mco(mco_coro *co) {
  return co ? (titan_coro_data *)mco_get_user_data(co) : NULL;
}

static mco_coro *titan_coro_transfer_source(mco_coro *co) {
  return (co && co->stacked_co) ? co->stacked_co : co;
}

static mco_coro *titan_coro_transfer_target(mco_coro *co) {
  return titan_coro_transfer_source(co);
}

static int titan_coro_tag_equal(void *t1, void *t2) {
  return luaV_equalobj(NULL, (const TValue *)t1, (const TValue *)t2);
}

static int titan_coro_pop_payload_value(mco_coro *co, TValue *payload) {
  return mco_pop(co, payload, sizeof(*payload));
}

static int titan_coro_push_transfer(mco_coro *co, int ok, TValue payload) {
  mco_result res = mco_push(co, &payload, sizeof(payload));
  if(res != MCO_SUCCESS) {
    return res;
  }
  res = mco_push(co, &ok, sizeof(ok));
  if(res != MCO_SUCCESS) {
    (void)titan_coro_pop_payload_value(co, &payload);
  }
  return res;
}

static int titan_coro_pop_ok_value(mco_coro *co, int *ok) {
  return mco_pop(co, ok, sizeof(*ok));
}

static void titan_coro_discard_transfer(mco_coro *co) {
  int ok;
  TValue payload;
  (void)titan_coro_pop_ok_value(co, &ok);
  (void)titan_coro_pop_payload_value(co, &payload);
}

typedef struct titan_coro_call {
  ptrdiff_t func;
} titan_coro_call;

static void titan_coro_call_noyield(lua_State *L, void *ud) {
  titan_coro_call *call = (titan_coro_call *)ud;
  luaD_callnoyield(L, restorestack(L, call->func), 1);
}

static int titan_coro_call_value(lua_State *L, titan_coro_data *data,
                                 TValue arg, TValue *result) {
  TValue func = titan_coro_get_uv(data, TITAN_CORO_UV_FUNC);
  ptrdiff_t old_errfunc = L->errfunc;
  CallInfo *old_ci = L->ci;
  lu_byte old_allowhook = L->allowhook;
  ptrdiff_t errfunc;
  ptrdiff_t funcslot;
  titan_coro_call call;
  TStatus status;
  StkId errslot;
  StkId resultslot;

  lua_checkstack(L, 3);
  lua_pushcfunction(L, errorhandler);
  errfunc = savestack(L, L->top.p - 1);
  L->errfunc = errfunc;

  funcslot = savestack(L, L->top.p);
  titan_coro_push_tvalue(L, &func);
  titan_coro_push_tvalue(L, &arg);

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

static void titan_coro_save_trace(lua_State *L, titan_coro_data *data) {
  int top = lua_gettop(L);
  lua_getfield(L, LUA_REGISTRYINDEX, TITAN_BACKTRACE_KEY);
  if(!lua_isnil(L, -1)) {
    TValue trace = *s2v(L->top.p - 1);
    titan_coro_set_uv(L, data, TITAN_CORO_UV_TRACE, &trace);
  }
  lua_settop(L, top);
}

static void titan_coro_restore_trace(lua_State *L, titan_coro_data *data) {
  TValue trace = titan_coro_get_uv(data, TITAN_CORO_UV_TRACE);
  if(!ttisnil(&trace)) {
    titan_coro_push_tvalue(L, &trace);
    lua_setfield(L, LUA_REGISTRYINDEX, TITAN_BACKTRACE_KEY);
    lua_pushboolean(L, 1);
    lua_setfield(L, LUA_REGISTRYINDEX, TITAN_TRACE_PINNED);
    titan_coro_clear_uv(L, data, TITAN_CORO_UV_TRACE);
  }
}

static int titan_coro_gc(lua_State *L) {
  mco_coro **slot = (mco_coro **)lua_touserdata(L, 1);
  if(slot && *slot) {
    mco_coro *co = *slot;
    titan_coro_data *data = titan_coro_data_from_mco(co);
    *slot = NULL;
    mco_destroy(co);
    free(data);
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
  titan_coro_data *data = titan_coro_data_from_mco(co);
  lua_State *T;
  int top;
  int status;
  int ok;
  TValue payload;

  if(!data || !data->thread) {
    return;
  }

  T = data->thread;
  top = lua_gettop(T);

  if(titan_coro_pop_ok_value(co, &ok) != MCO_SUCCESS ||
     titan_coro_pop_payload_value(co, &payload) != MCO_SUCCESS) {
    setnilvalue(&payload);
    titan_coro_push_transfer(co, 0, payload);
    lua_settop(T, top);
    return;
  }

  if(!ok) {
    titan_coro_push_transfer(co, 0, payload);
    lua_settop(T, top);
    return;
  }

  status = titan_coro_call_value(T, data, payload, &payload);
  if(status == LUA_OK) {
    ok = 1;
  } else {
    ok = 0;
    titan_coro_save_trace(T, data);
  }
  titan_coro_push_transfer(co, ok, payload);
}

TValue titan_coro_create(lua_State *L, TValue func) {
  int top = lua_gettop(L);
  Udata *ud;
  mco_coro **slot;
  titan_coro_data *data;
  lua_State *thread;
  TValue threadv;
  TValue result;
  mco_desc desc;
  mco_result res;

  (void)titan_coro_ensure_metatable(L);
  lua_newuserdatauv(L, sizeof(mco_coro *), TITAN_CORO_NUV);
  ud = uvalue(s2v(L->top.p - 1));
  slot = (mco_coro **)getudatamem(ud);
  *slot = NULL;
  luaL_getmetatable(L, "titan.coro");
  lua_setmetatable(L, -2);

  lua_newthread(L);
  thread = lua_tothread(L, -1);
  threadv = *s2v(L->top.p - 1);
  titan_coro_set_ud_uv(L, ud, TITAN_CORO_UV_THREAD, &threadv);
  lua_pop(L, 1);

  data = (titan_coro_data *)calloc(1, sizeof(*data));
  if(!data) {
    luaL_error(L, "could not create coroutine: out of memory");
  }
  data->handle = ud;
  data->thread = thread;
  titan_coro_set_uv(L, data, TITAN_CORO_UV_FUNC, &func);
  titan_coro_clear_uv(L, data, TITAN_CORO_UV_TRACE);

  mco_set_tag_comparator(titan_coro_tag_equal);
  desc = mco_desc_init(titan_coro_entry, TITAN_CORO_STACK_SIZE);
  desc.user_data = data;
  res = mco_create(slot, &desc);
  if(res != MCO_SUCCESS) {
    free(data);
    *slot = NULL;
    luaL_error(L, "could not create coroutine: %s", mco_result_description(res));
  }
  result = *s2v(L->top.p - 1);
  lua_settop(L, top);
  return result;
}

int titan_coro_push(lua_State *L, TValue handle, int ok, TValue payload) {
  mco_coro *target = titan_coro_transfer_target(titan_coro_co_from_value(L, handle));
  (void)L;
  if(!target) return MCO_INVALID_COROUTINE;
  return titan_coro_push_transfer(target, ok, payload);
}

int titan_coro_push_current(lua_State *L, int ok, TValue payload) {
  mco_coro *co = mco_running();
  (void)L;
  if(!co) return MCO_INVALID_COROUTINE;
  return titan_coro_push_transfer(co, ok, payload);
}

int titan_coro_resume(lua_State *L, TValue handle, TValue tag) {
  mco_coro *co = titan_coro_co_from_value(L, handle);
  mco_coro *target = titan_coro_transfer_target(co);
  mco_result res;
  if(!co) return MCO_INVALID_COROUTINE;
  mco_set_tag_comparator(titan_coro_tag_equal);
  res = mco_resume(co, &tag);
  if(res != MCO_SUCCESS) {
    if(target) {
      titan_coro_discard_transfer(target);
    }
  }
  return res;
}

int titan_coro_yield(lua_State *L, TValue tag) {
  mco_coro *co = mco_running();
  mco_result res;
  (void)L;
  if(!co) return MCO_INVALID_COROUTINE;
  mco_set_tag_comparator(titan_coro_tag_equal);
  res = mco_yield(co, &tag);
  if(res != MCO_SUCCESS) {
    titan_coro_discard_transfer(co);
  }
  return res;
}

int titan_coro_pop_ok(lua_State *L, TValue handle) {
  mco_coro *source = titan_coro_transfer_source(titan_coro_co_from_value(L, handle));
  titan_coro_data *data = titan_coro_data_from_mco(source);
  int ok;
  if(!source || titan_coro_pop_ok_value(source, &ok) != MCO_SUCCESS) {
    return 0;
  }
  if(data && !ok) {
    titan_coro_restore_trace(L, data);
  }
  return ok;
}

TValue titan_coro_pop_payload(lua_State *L, TValue handle) {
  mco_coro *source = titan_coro_transfer_source(titan_coro_co_from_value(L, handle));
  TValue nilv;
  TValue payload;
  setnilvalue(&nilv);
  (void)L;
  if(source && titan_coro_pop_payload_value(source, &payload) == MCO_SUCCESS) {
    return payload;
  }
  return nilv;
}

int titan_coro_pop_current_ok(lua_State *L) {
  mco_coro *co = mco_running();
  int ok;
  (void)L;
  if(!co || titan_coro_pop_ok_value(co, &ok) != MCO_SUCCESS) {
    return 0;
  }
  return ok;
}

TValue titan_coro_pop_current_payload(lua_State *L) {
  mco_coro *co = mco_running();
  TValue nilv;
  TValue payload;
  setnilvalue(&nilv);
  (void)L;
  if(co && titan_coro_pop_payload_value(co, &payload) == MCO_SUCCESS) {
    return payload;
  }
  return nilv;
}

int titan_coro_is_yieldable(lua_State *L, TValue tag) {
  mco_coro *co = mco_running();
  (void)L;
  mco_set_tag_comparator(titan_coro_tag_equal);
  return co && mco_is_yieldable(co, &tag);
}

int titan_coro_status(lua_State *L, TValue handle) {
  mco_coro *co = titan_coro_co_from_value(L, handle);
  (void)L;
  if(!co) return TITAN_CORO_STATUS_DEAD;
  switch(mco_status(co)) {
    case MCO_SUSPENDED: return TITAN_CORO_STATUS_SUSPENDED;
    case MCO_RUNNING: return TITAN_CORO_STATUS_RUNNING;
    case MCO_NORMAL: return TITAN_CORO_STATUS_NORMAL;
    case MCO_STACKED: return TITAN_CORO_STATUS_STACKED;
    case MCO_DEAD: return TITAN_CORO_STATUS_DEAD;
  }
  return TITAN_CORO_STATUS_DEAD;
}

char *titan_coro_result_name(int result) {
  return (char *)mco_result_description((mco_result)result);
}
