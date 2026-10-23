#ifndef TITAN_FFI_H
#define TITAN_FFI_H

#include "lauxlib.h"
#include "ldo.h"
#include "lobject.h"
#include "lstate.h"
#include "lgc.h"
#include "lua.h"

/* Runtime helpers are linked into each Titan provider. A shared Lua DLL may
** export Lua internals, but does not own these helpers. Keep their existing
** ELF/Mach-O visibility and use ordinary extern declarations elsewhere. */
#if defined(__GNUC__) && ((__GNUC__*100 + __GNUC_MINOR__) >= 302) && \
    (defined(__ELF__) || defined(__MACH__))
#define TITAN_RUNTIME_FUNC __attribute__((visibility("internal"))) extern
#else
#define TITAN_RUNTIME_FUNC extern
#endif

/* Immutable native symbol capability; no Lua/Titan value belongs to it. */
typedef void *(*TitanModuleSymbols)(const char *symbol);
#define TITAN_MODULE_PRELOADS_KEY "Titan module preload providers"

/* The immutable resolver belongs to the image that created this module state.
** Every generated module's native payload starts with this exact header. */
typedef struct TitanModuleData {
  TitanModuleSymbols symbols;
} TitanModuleData;

/* These owning-state helpers reserve their temporary stack and preserve the
** entry top on success. They may allocate/raise. Names are length-aware so a
** native preload with an embedded zero byte never aliases another module.
** A NULL resolver publishes an ordinary native loader without a descriptor. */
TITAN_RUNTIME_FUNC TitanModuleSymbols titan_module_preload_symbols(lua_State *L,
    const char *name, size_t length, lua_CFunction loader);
TITAN_RUNTIME_FUNC void titan_module_preload(lua_State *L, const char *name,
    size_t length, lua_CFunction loader, TitanModuleSymbols symbols);

#if defined(__unix__) || defined(__APPLE__)
#include <sys/socket.h>

/* glibc's GNU getsockname declaration uses a transparent-union argument,
** which Titan's C importer does not support. Expose the ordinary POSIX
** sockaddr-pointer signature without changing the call or its errno. */
static inline int titan_posix_getsockname(int descriptor,
                                         struct sockaddr *address,
                                         socklen_t *length) {
  return getsockname(descriptor, address, length);
}
#endif

/*
** Macro to convert between function pointers and object/void pointers.
** These casts are not portable ISO C, but the supported toolchains and
** POSIX dynamic-symbol contract provide them. (The '__extension__' in GNU
** compilers is only to avoid warnings.)
** Named titan_cast_func because Lua 5.5's llimits.h defines its own
** single-argument cast_func.
*/
#if defined(__GNUC__)
#define titan_cast_func(t, p) (__extension__(t)(p))
#else
#define titan_cast_func(t, p) ((t)(p))
#endif

/* Opaque ABI-owned brand stored as light userdata in every Titan function
** closure. It is compared only as raw pointer bits and must never be
** dereferenced. Together with the fixed upvalue slot/count, this
** astronomically unlikely sentinel distinguishes Titan closures without a
** Lua-registry lookup on generic calls. */
#define TITAN_BRAND ((void *)(uintptr_t)UINT64_C(0x649b61b49f68a8b2))

/* Implementation notes: doc/implementation/lua-interop-internals.md#discoverable-runtime-type-information */
#define TITAN_MT_TYPE ((void *)(uintptr_t)UINT64_C(0xD70BB58499779830))
#define TITAN_MT_STATICS ((void *)(uintptr_t)UINT64_C(0x83370ABAA56047AE))
#define TITAN_MT_MEMBERMAP ((void *)(uintptr_t)UINT64_C(0x310D781561E92F6D))
#define TITAN_MT_MOD ((void *)(uintptr_t)UINT64_C(0x54C6087BF019D23A))
#define TITAN_MT_PAYLOAD ((void *)(uintptr_t)UINT64_C(0xB7D24E619053AC8F))
#define TITAN_MT_PROJECT ((void *)(uintptr_t)UINT64_C(0x730AB98A6741201C))
#define TITAN_MT_CONSTRUCT ((void *)(uintptr_t)UINT64_C(0x730AB98A6741201D))
#define TITAN_MT_PUBLIC ((void *)(uintptr_t)UINT64_C(0x730AB98A6741201E))
/* Generated nominal codec bound by the declaring module (see transfer.h). */
#define TITAN_MT_CODEC ((void *)(uintptr_t)UINT64_C(0x730AB98A6741201F))

/*
** Titan types that have a metatable
*/
#define TITAN_ARRAY 1
#define TITAN_CONST_ARRAY 2
#define TITAN_RECORD 3
#define TITAN_UNION 4
#define TITAN_INTERFACE 5
#define TITAN_OWNED 6

#define TITAN_BACKTRACE_KEY "57d80578-2534-4856-ad3b-bde8cba4c445"
/* When set (boolean true) in the registry, errorhandler() KEEPS the existing
** TITAN_BACKTRACE_KEY slot instead of regenerating it, and clears the pin. A
** pending re-raise sets the pin so the original error's trace is preserved; a
** fresh error leaves it clear so it gets a freshly-captured trace. */
#define TITAN_TRACE_PINNED "5b3f0f7e-4b1a-4d2e-9a8c-2f6d4c1e7a90"
/* Temporary handoff slot used by Titan coroutines. A dead coroutine entry
** stages its own trace here; the resume/error side captures a new propagation
** trace, appends it, stores the combined trace in TITAN_BACKTRACE_KEY, and
** sets TITAN_TRACE_PINNED for the final re-raise. */
#define TITAN_TRACE_APPEND_KEY "4f895b66-bae0-4e97-afb3-83a31f2f9e96"
#define TITAN_MAIN_BOOTSTRAP_KEY "41c48a97-55a5-4514-a76f-79ab028ae6e0"
#define TITAN_MAIN_ARGC_KEY "fd9c8d85-f521-4052-92e6-8af5c349e5bb"
#define TITAN_MAIN_ARGV_KEY "fc1376f3-2cb7-48d4-969c-c02df930cf68"
#define TITAN_METATABLES_KEY "9db55616-03e8-4dec-8077-618025b1bb69"

#ifdef __GNUC__
#define TITAN_LIKELY(x) __builtin_expect((x), 1)
#define TITAN_UNLIKELY(x) __builtin_expect((x), 0)
#define TITAN_UNUSED __attribute__((unused))
#define TITAN_NOINLINE __attribute__((noinline))
#else
#define TITAN_LIKELY(x) (x)
#define TITAN_UNLIKELY(x) (x)
#define TITAN_UNUSED
#define TITAN_NOINLINE
#endif

int errorhandler(lua_State *L);

/* True while a __gc finalizer runs (ordinary collection or lua_close). GCTM
** sets GCSTPGC around every finalizer call; no other running code sees it. */
/* Implementation notes: doc/implementation/coroutines.md#finalizer-context */
static inline int titan_in_finalizer(lua_State *L) {
  return (G(L)->gcstp & GCSTPGC) != 0;
}

/* True while lua_close runs: luaC_freeallobjects sets GCSTPCLS before calling
** the pending finalizers. Lua ignores new finalizer registrations from then on,
** and no async Runtime loop runs again. */
/* Implementation notes: doc/implementation/libuv-runtime.md#lua-state-close-of-an-unretired-runtime */
static inline int titan_state_closing(lua_State *L) {
  return (G(L)->gcstp & GCSTPCLS) != 0;
}

/* Continue an abandoned-coroutine unwind from the current frame: jump to the
** next finally boundary or coroutine floor on L's error-recovery chain,
** closing exhausted Lua coroutines on the way. Never returns. */
TITAN_RUNTIME_FUNC l_noret titan_unwind(lua_State *L);

struct mco_coro;
typedef void (*titan_coroutine_entry)(lua_State *, Udata *, CClosure *, TValue,
                                      struct mco_coro *);
/* Run a coroutine entry above an unwind floor on its thread T. An unwind that
** reaches the floor closes T's remaining Lua frames and finishes the
** coroutine with an unwind transfer; a real error that escapes the entry is
** delivered to the resumer as an error transfer. */
TITAN_RUNTIME_FUNC void titan_coroutine_enter(lua_State *T, Udata *module,
    TValue func, struct mco_coro *co, titan_coroutine_entry entry);

static inline TValue lua_totvalue(lua_State *L, int idx) {
  if (TITAN_UNLIKELY(idx > 0)) {
    return *s2v(L->ci->func.p + idx);
  }
  if (TITAN_LIKELY(idx > LUA_REGISTRYINDEX)) {
    return *s2v(L->top.p + idx);
  }
  if (TITAN_LIKELY(idx < LUA_REGISTRYINDEX)) {
    return clCvalue(s2v(L->ci->func.p))->upvalue[LUA_REGISTRYINDEX - idx - 1];
  }
  return G(L)->l_registry;
}

static inline void lua_pushtvalue(lua_State *L, TValue value) {
  setobj2s(L, L->top.p, &value);
  L->top.p++;
}

/* Lightuserdata preserves address bits and exposes no pointed-to storage. */
static inline void lua_pushconstlightuserdata(lua_State *L, const void *value) {
  lua_pushlightuserdata(L, (void *)value);
}

static inline void *lua_togco(lua_State *L, int idx) {
  TValue value = lua_totvalue(L, idx);
  return gcvalue(&value);
}

static inline lua_State *titan_newthread(lua_State *L) {
  lua_State *thread = lua_newthread(L);
  /* Native coroutine entry bypasses a Lua entry wrapper. Reserve enough
   * stack while the parent call still owns the ordinary protected boundary,
   * so the generated function-scope catch can install its jump target before
   * its first potentially allocating GC check. */
  if (TITAN_UNLIKELY(!lua_checkstack(thread, LUA_MINSTACK)))
    luaL_error(L, "cannot reserve stack for Titan coroutine entry");
  lua_pushcfunction(thread, errorhandler);
  thread->errfunc = savestack(thread, thread->top.p - 1);
  return thread;
}

/* Implementation notes: doc/implementation/ffi-internals.md#header-support-files */
static inline lua_State *lmacro_thvalue(const TValue *o) { return thvalue(o); }

static inline Udata *lmacro_uvalue(const TValue *o) { return uvalue(o); }

static inline CClosure *lmacro_clCvalue(const TValue *o) { return clCvalue(o); }

static inline void *lmacro_pvalue(const TValue *o) { return pvalue(o); }

static inline int lmacro_ttype(const TValue *o) { return ttype(o); }

static inline int lmacro_ttypetag(const TValue *o) { return ttypetag(o); }

static inline int lmacro_ttisLclosure(const TValue *o) {
  return ttisLclosure(o);
}

static inline int lmacro_ttisCclosure(const TValue *o) {
  return ttisCclosure(o);
}

static inline int lmacro_ttisfulluserdata(const TValue *o) {
  return ttisfulluserdata(o);
}

static inline int lmacro_ttislcf(const TValue *o) { return ttislcf(o); }

static inline int lmacro_ttislightuserdata(const TValue *o) {
  return ttislightuserdata(o);
}

static inline lua_CFunction lmacro_fvalue(const TValue *o) { return fvalue(o); }

static inline void *lmacro_getudatamem(Udata *u) { return getudatamem(u); }

static inline void *lmacro_ccl_f(const CClosure *cl) {
  return titan_cast_func(void *, cl->f);
}

/* `o` is an untyped collectable object; cast it directly, because `obj2gco`
 * reads its tag under LUAI_ASSERT and `void *` has none. */
static inline void lmacro_luaC_barrierback(lua_State *L, void *o,
                                           const TValue *v) {
  luaC_barrierback(L, (GCObject *)o, v);
}

typedef void (*generic_func_ptr)(void);

static inline generic_func_ptr titan_ptof(void *p) {
  return titan_cast_func(generic_func_ptr, p);
}

static inline void *titan_ftop(generic_func_ptr f) {
  return titan_cast_func(void *, f);
}

static inline void lmacro_sethvalue(lua_State *L, TValue *o, Table *t) {
  sethvalue(L, o, t);
}

#endif
