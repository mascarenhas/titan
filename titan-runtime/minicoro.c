#include "lobject.h"
#include "lvm.h"
#include "titan.h"

static int minicoro_tag_equal(void *t1, void *t2);

#define MCO_NO_DEBUG
#define MCO_USE_VMEM_ALLOCATOR
#define MCO_TAG_COMPARATOR minicoro_tag_equal
#define MINICORO_IMPL
#include "minicoro.h"

/* Implementation notes: doc/implementation/coroutines.md#tagged-minicoro */
static int minicoro_tag_equal(void *t1, void *t2) {
  return luaV_equalobj(NULL, (const TValue *)t1, (const TValue *)t2);
}

/* Matches titan/coroutine.titan: TITAN_CORO_TRANSFER_USERVALUE (1-based 5)
** and the transfer flags of a returned and of an unwound coroutine. */
#define TITAN_CORO_TRANSFER_UV_INDEX 4
#define TITAN_CORO_TRANSFER_VALUE 1
#define TITAN_CORO_TRANSFER_UNWIND 2

static void titan_coroutine_abort(const char *why) {
  fprintf(stderr, "titan: coroutine entry: %s\n", why);
  fflush(stderr);
  abort();
}

/* Push the final (payload, ok) transfer of a coroutine whose entry did not
** push its own, rooting the payload in the owner's transfer uservalue first,
** exactly as push_transfer in titan/coroutine.titan does. The storage is
** empty here: the request was popped and the entry pushed nothing. */
static void titan_coroutine_push_final(lua_State *T, mco_coro *co,
                                       const TValue *payload, int ok) {
  Udata *owner = (Udata *)mco_get_user_data(co);
  TValue value;
  if (payload != NULL) {
    setobj(T, &value, payload);
  } else {
    setnilvalue(&value);
  }
  setobj(T, &owner->uv[TITAN_CORO_TRANSFER_UV_INDEX].uv, &value);
  luaC_barrierback(T, obj2gco(owner), &value);
  if (mco_push(co, &value, sizeof(TValue)) != MCO_SUCCESS ||
      mco_push(co, &ok, sizeof(int)) != MCO_SUCCESS)
    titan_coroutine_abort("cannot push the final coroutine transfer");
}

/* Implementation notes: doc/implementation/coroutines.md#unwinding-an-abandoned-coroutine */
void titan_coroutine_enter(lua_State *T, Udata *module, TValue func,
                           struct mco_coro *co, titan_coroutine_entry entry) {
  l_uint32 oldnC = T->nCcalls;
  CallInfo *oldci = T->ci;
  lu_byte oldah = T->allowhook;
  ptrdiff_t oldtop = savestack(T, T->top.p);
  ptrdiff_t olderrfunc = T->errfunc;
  titan_unwind_floor floor;
  floor.stack_low = (uintptr_t)co->stack_base;
  floor.stack_high = floor.stack_low + (uintptr_t)co->stack_size;
  floor.unwinding = 0;
  floor.lj.status = TITAN_STATUS_FLOOR;
  floor.lj.previous = T->errorJmp;
  T->errorJmp = &floor.lj;
  if (TITAN_SETJMP(floor.lj.b) == 0) {
    entry(T, module, NULL, func, co);
  } else {
    /* The jump removed every native frame above the floor: unlink the frames'
    ** boundaries and restore the saved call state, C-call count included,
    ** before running any close method. */
    T->errorJmp = floor.lj.previous;
    T->nCcalls = oldnC;
    T->ci = oldci;
    T->allowhook = oldah;
    T->errfunc = olderrfunc;
    if (floor.unwinding && floor.lj.status != TITAN_STATUS_UNWIND) {
      /* T is being abandoned, but a cleanup closed T's own thread
      ** (coroutine.close() with no argument), and luaD_throwbaselevel jumped
      ** here past every guard. The unwind dominates: an error from a __close
      ** of that self-close becomes a cleanup warning and is dropped, so the
      ** resumer keeps unwinding and can never catch it. */
      if (floor.lj.status != LUA_OK) titan_unwind_report(T, floor.lj.status);
      floor.lj.status = TITAN_STATUS_UNWIND;
    }
    if (floor.lj.status != TITAN_STATUS_UNWIND && floor.lj.status != LUA_OK) {
      /* A real error escaped the entry's catch. Close the Lua frames above
      ** with it, as luaD_pcall does, under the floor re-armed: a __close that
      ** suspends this coroutine leaves it abandonable, and an unwind then
      ** lands here again with TITAN_STATUS_UNWIND and drops the error.
      ** luaD_closeprotected catches every error of a __close itself. */
      volatile TStatus error_status = floor.lj.status;
      floor.lj.status = TITAN_STATUS_FLOOR;
      T->errorJmp = &floor.lj;
      if (TITAN_SETJMP(floor.lj.b) == 0) {
        floor.lj.status = luaD_closeprotected(T, oldtop, error_status);
      } else {
        T->nCcalls = oldnC;
        T->ci = oldci;
        T->allowhook = oldah;
        T->errfunc = olderrfunc;
        /* The unwind drops the escaped error: clear its trace and pin. */
        titan_unwind_clear_trace(T);
      }
      T->errorJmp = floor.lj.previous;
    }
    if (floor.lj.status == TITAN_STATUS_UNWIND) {
      /* Every Titan finally on T has run, or T's abandonment ended in a
      ** self-close: close the remaining Lua frames and finish the coroutine
      ** as unwound, so its resumer keeps unwinding instead of returning. */
      titan_unwind_close(T, oldtop);
      titan_coroutine_push_final(T, co, NULL, TITAN_CORO_TRANSFER_UNWIND);
    } else if (floor.lj.status == LUA_OK) {
      /* Lua code on T closed its own thread (coroutine.close() with no
      ** argument): lua_closethread already closed every variable, and
      ** luaD_throwbaselevel jumped here. Finish as dead with no result, like
      ** a Lua coroutine that closes itself. */
      titan_coroutine_push_final(T, co, NULL, TITAN_CORO_TRANSFER_VALUE);
    } else {
      /* Deliver the real error to the resumer. */
      luaD_seterrorobj(T, floor.lj.status, restorestack(T, oldtop));
      titan_coroutine_push_final(T, co, s2v(T->top.p - 1), 0);
    }
    T->top.p = restorestack(T, oldtop);
  }
  T->errorJmp = floor.lj.previous;
  T->nCcalls = oldnC;
}
