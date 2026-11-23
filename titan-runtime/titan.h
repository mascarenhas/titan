#ifndef TITAN_H
#define TITAN_H

#include <float.h>
#include <errno.h>
#include <math.h>
#include <setjmp.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(__wasm__)
#include <llimits.h>
#include <lobject.h>
#include <lstring.h>
#include <ltable.h>
#include <luaconf.h>
#include <lvm.h>
#else
#include "llimits.h"
#include "lobject.h"
#include "lstring.h"
#include "ltable.h"
#include "luaconf.h"
#include "lvm.h"
#endif

/*
** Small trusted Lua-internal value bridges live with their FFI declarations.
** Includes shared macros and inline functions between the C FFI and the Titan
** runtime
*/
#include "titan/ffi.h"
#include "transfer.h"

/*
** ===========================================================================
** VENDORED FROM Lua 5.5.1 src/ldo.c lines 61-109 (keep VERBATIM; re-sync on
** every Lua upgrade). The struct must stay byte-compatible with the linked
** liblua.a: lstate.h only forward-declares `struct lua_longjmp`, so providing
** the full definition here is conflict-free, and the generated module C uses it
** to install an inline setjmp boundary for catch/finally without calling into
** Lua's (private) luaD_rawrunprotected with a thunk.
**
** Titan generates C and builds Lua with longjmp (the `make lua` build), so the
** C++-exception arm of the upstream ladder is intentionally OUT OF SCOPE here:
** we only vendor the _setjmp/setjmp arms and add a statement-form TITAN_SETJMP
** selected by the SAME #ifdef ladder.
** ===========================================================================
*/

/* Implementation notes: doc/implementation/error-handling.md#code-generator-overview */
/* --- BEGIN verbatim from lua-5.5.1/src/ldo.c:61-65 --- */

/* chained list of long jump buffers */
typedef struct lua_longjmp {
  struct lua_longjmp *previous;
  jmp_buf b;
  volatile TStatus status; /* error code */
} lua_longjmp;

/* --- END verbatim --- */

/*
** Statement-form setjmp selector, mirroring the upstream LUAI_THROW/LUAI_TRY
** #ifdef ladder (lua-5.5.1/src/ldo.c:74-107) but expressed as a value usable in
** an `if (TITAN_SETJMP(buf) == 0) { ... }` boundary (the upstream LUAI_TRY is
** function-form and takes a Pfunc; we cannot use it for inline straight-line
* C).
** The same selection (_setjmp on POSIX, setjmp otherwise) keeps the buffer
** read/written by the same routine the linked liblua.a uses for LUAI_THROW.
*/
#if defined(__wasm__) && defined(LUA_USE_POSIX)
int _setjmp(jmp_buf) __attribute__((__returns_twice__));
_Noreturn void _longjmp(jmp_buf, int);
#endif
#if defined(LUA_USE_POSIX)
#define TITAN_SETJMP(buf) _setjmp(buf)
#else
#define TITAN_SETJMP(buf) setjmp(buf)
#endif

/*
** Abandoned-coroutine unwinding. Generated code initializes the status of a
** finally-bearing boundary to TITAN_STATUS_FINALLY instead of LUA_OK; Lua only
** ever writes a status from luaD_throw immediately before jumping, so the
** marker survives until the boundary exits or titan_unwind lands there with
** TITAN_STATUS_UNWIND. The coroutine entry floor carries TITAN_STATUS_FLOOR
** and records the real bounds of its minicoro stack. None of these values is
** a Lua status (0..6, or -1 for C++ exceptions).
*/
/* Implementation notes: doc/implementation/coroutines.md#unwinding-an-abandoned-coroutine */
#define TITAN_STATUS_FINALLY ((TStatus)0x54)
#define TITAN_STATUS_UNWIND ((TStatus)0x55)
#define TITAN_STATUS_FLOOR ((TStatus)0x56)

/* The jump paired with TITAN_SETJMP, mirroring LUAI_THROW's selection: it must
** not restore a signal mask that TITAN_SETJMP did not save. glibc declares
** _longjmp only for __USE_MISC/__USE_XOPEN, unlike _setjmp, so a strict-ISO
** compile of this header cannot name it. There longjmp is the same routine
** (glibc aliases longjmp, _longjmp and siglongjmp), and it restores a mask
** only when the buffer recorded one, which _setjmp never does. Other POSIX C
** libraries (macOS, BSDs, musl) declare _setjmp and _longjmp together. */
#if defined(LUA_USE_POSIX) && !defined(__GLIBC__)
#define TITAN_LONGJMP(buf) _longjmp(buf, 1)
#else
#define TITAN_LONGJMP(buf) longjmp(buf, 1)
#endif

#ifndef TITAN_COROUTINE_STACK_SIZE
#define TITAN_COROUTINE_STACK_SIZE (2 * 1024 * 1024)
#endif

/* The bottom boundary of a Titan coroutine's Lua thread. `lj` is the first
** member, so the boundary pointer is also the record pointer. The bounds are
** integer addresses of the real coroutine stack, never of this object.
** `unwinding` is set by the walker before it lands on any boundary of the
** thread, so the floor still knows the coroutine is being abandoned when a
** cleanup's self-close (luaD_throwbaselevel) jumps here past every guard. */
typedef struct titan_unwind_floor {
  lua_longjmp lj;
  uintptr_t stack_low;
  uintptr_t stack_high;
  volatile int unwinding;
} titan_unwind_floor;

/* Close every to-be-closed variable at or above `level` (a savestack offset)
** with no error value, reporting and dropping each error; never raises. */
TITAN_RUNTIME_FUNC TITAN_COLD void titan_unwind_close(lua_State *L, ptrdiff_t level);
/* Report the error of `status`, whose object is on top of the stack for a
** runtime error, as one "error in coroutine cleanup (...)" warning and drop
** it; never raises. */
TITAN_RUNTIME_FUNC TITAN_COLD void titan_unwind_report(lua_State *L, TStatus status);
/* Clear the registry trace and pin of an error that an unwind dropped, as a
** catch recovery does; never raises. */
TITAN_RUNTIME_FUNC TITAN_COLD void titan_unwind_clear_trace(lua_State *L);
/* An error escaped a finally body that runs during an unwind: unlink the
** guard, restore the boundary state, report the error, close the Lua frames
** above `level` and continue the unwind. Never returns. */
TITAN_RUNTIME_FUNC TITAN_COLD l_noret titan_unwind_guard_failed(lua_State *L,
    lua_longjmp *guard, l_uint32 oldnC, CallInfo *oldci, lu_byte oldah,
    ptrdiff_t olderrfunc, ptrdiff_t level);

/* TITAN_ABI_VERSION is the monotonic compiled-module compatibility integer,
   encoded as a canonical decimal string in module metadata. TITAN_VERSION is
   the compiler and standard-library semantic version.
   TITAN_LIBRARY_VERSION is its major/minor component and owns installed
   library paths plus the versioned TITAN_PATH override. */
/* Implementation notes: doc/implementation/codegen-overview.md#compiled-module-abi */
#define TITAN_ABI_VERSION "2"
#define TITAN_VERSION "0.6.1"
#define TITAN_LIBRARY_VERSION "0.6"
#define TITAN_LIBRARY_VERSION_SUFFIX "_0_6"
#define TITAN_PATH_VAR "TITAN_PATH"
#define TITAN_PATH_SEP "/"
/* Registry string: this Lua state's effective Titan path, a `;`-separated
** list of provider directories. titan_path.c computes it on the first lookup;
** a string an application stores here first is used as-is (no `;;` or `!`
** expansion and no SDK fallback). */
#define TITAN_PATH_KEY "ec10e486-d8fd-11e7-87f4-e7e9581a929c"
#define TITAN_LIBS_KEY "ecfc9174-d8fd-11e7-8be2-abbaa3ded45f"
#define TITAN_BT_STATE_KEY "a222927d-0e7b-4f7a-93d9-1a6ce7111a5c"

/* Registry sub-table mapping a native Titan C symbol name (the mangled name the
** coder emits for a function/method/static/anonymous native entry) -> the
** qualified Titan source name to display in a trace ("<module>.<func>",
** "<module>.<record>:<method>", "<module>.<record>.<static>", or "anonymous
** function at <file>.titan:<linedefined>"). Each module's _init lazily creates
** the sub-table (multiple modules contribute) and populates it for every native
** function it generates. errorhandler looks each native frame's DWARF symbol up
** here and shows the qualified name when found, falling back to the raw symbol.
** A runtime/_init addition only: it does not by itself change the compiled
** module ABI. */
#define TITAN_NAMES_KEY "a7c4e2f0-1d6b-4e3a-9c5f-8b2d7e0a4f16"
#ifdef TITAN_TARGET_BROWSER
/* Light C-function keys, registered before browser module initialization. */
#define TITAN_ENTRIES_KEY "0c6fbc42-27b4-497f-a6f3-3c9e1f4d7b20"
#endif

#define TITAN_LUAINTEGER_NBITS cast_int(sizeof(lua_Integer) * CHAR_BIT)

/*
** Dense Titan Arrays use an ordinary Lua Table as their exact/native backing
** object, but reserve its hash key 0 for the canonical Lua-visible proxy.
** Keep this limit textually aligned with Lua 5.5's private MAXASIZE formula:
** every positive Array index must fit in the table's array part, with no hash
** fallback.
*/
#define TITAN_ARRAY_METATABLE "Titan array metatable"
#define TITAN_CONST_ARRAY_METATABLE "Titan const array metatable"
#define TITAN_ARRAY_MAX_CAPACITY                                               \
  (((1u << (l_numbits(int) - 1)) < (MAX_SIZET / (sizeof(Value) + 1)))          \
       ? (1u << (l_numbits(int) - 1))                                          \
       : cast_uint(MAX_SIZET / (sizeof(Value) + 1)))

/*
** One copied entry in an Interface wrapper's opaque payload. Generated code
** converts concrete native method pointers to this storage type and back
** through titan_cast_func; the payload never contains data pointers.
*/
typedef void (*TitanInterfaceMethod)(void);

/* Implementation notes: doc/implementation/variadic-parameters.md#seven-titanvarg-structs-one-per-ctype */
/* Variadic-parameter descriptors. One per `ctype` so `args` has the exact
** element pointer type. `n_args` is the TOTAL backing count; `start` is NOT a
** struct field — it travels as a separate `int _start` native parameter, so a
** callee's logical view is `args[start .. n_args-1]` and forwarding never
** mutates a shared descriptor. Static call sites point these descriptors at
** typed C-stack arrays; runtime-sized forwarding points them at anchored
** userdata storage. */
typedef struct {
  lu_byte n_args;
  lua_Integer *args;
} TitanVargInteger;
typedef struct {
  lu_byte n_args;
  lua_Number *args;
} TitanVargFloat;
typedef struct {
  lu_byte n_args;
  int *args;
} TitanVargBoolean;
typedef struct {
  lu_byte n_args;
  TString **args;
} TitanVargString;
typedef struct {
  lu_byte n_args;
  Table **args;
} TitanVargArrayOrMap;
typedef struct {
  lu_byte n_args;
  TValue *args;
} TitanVargValue;
typedef struct {
  lu_byte n_args;
  Udata **args;
} TitanVargNominal;
/* The `lu_byte` count is an intentional cap that keeps the struct small and
** bounds static sizing; runtime counts (forwarding/merge, the generic entry)
** are checked against this and raise a clean Titan error when exceeded. */
#define TITAN_VARARG_MAX 200

/* The module state object is a Udata (was a CClosure): push it as a full
   userdata value. Used to seed a function/method/metamethod closure's
   upvalue[0] with the module, and to put the module on the stack. */
#define titan_pushmodule(L, c)                                                 \
  {                                                                            \
    setuvalue(L, s2v(L->top.p), (c));                                          \
    L->top.p++;                                                                \
  }

/*
** Lua 5.5 removed setbvalue (booleans carry no payload; truth lives in
** the tag). This sets a boolean TValue from a C int.
*/
#define titan_setbvalue(obj, x)                                                \
  do {                                                                         \
    if (x) {                                                                   \
      setbtvalue(obj);                                                         \
    } else {                                                                   \
      setbfvalue(obj);                                                         \
    }                                                                          \
  } while (0)

/* Whether a lua_Integer converts to lua_Number with no rounding — replicated
** from lvm.c (l_intfitsf lives only in the .c file). NBM = float mantissa bits.
* */
#define TITAN_NBM (l_floatatt(MANT_DIG))
#if ((((LUA_MAXINTEGER >> (TITAN_NBM / 4)) >> (TITAN_NBM / 4)) >>              \
      (TITAN_NBM / 4)) >>                                                      \
     (TITAN_NBM - (3 * (TITAN_NBM / 4)))) > 0
#define TITAN_MAXINTFITSF ((lua_Unsigned)1 << TITAN_NBM)
#define titan_intfitsf(i)                                                      \
  ((TITAN_MAXINTFITSF + l_castS2U(i)) <= (2 * TITAN_MAXINTFITSF))
#else
#define titan_intfitsf(i) 1
#endif

/* i < f  (mirrors LTintfloat): i < f  <=>  i < ceil(f) when i doesn't fit a
 * float */
static l_inline int titan_lt_intfloat(lua_Integer i, lua_Number f) {
  if (titan_intfitsf(i))
    return luai_numlt(cast_num(i), f);
  else {
    lua_Integer fi;
    lua_Number ff = l_floor(f);
    if (ff != f)
      ff += 1; /* F2Iceil */
    if (lua_numbertointeger(ff, &fi))
      return i < fi;
    else
      return f > 0; /* f beyond integer range */
  }
}
/* i <= f  (LEintfloat): i <= floor(f) */
static l_inline int titan_le_intfloat(lua_Integer i, lua_Number f) {
  if (titan_intfitsf(i))
    return luai_numle(cast_num(i), f);
  else {
    lua_Integer fi;
    lua_Number ff = l_floor(f); /* F2Ifloor */
    if (lua_numbertointeger(ff, &fi))
      return i <= fi;
    else
      return f > 0;
  }
}
/* f < i  (LTfloatint): floor(f) < i */
static l_inline int titan_lt_floatint(lua_Number f, lua_Integer i) {
  if (titan_intfitsf(i))
    return luai_numlt(f, cast_num(i));
  else {
    lua_Integer fi;
    lua_Number ff = l_floor(f); /* F2Ifloor */
    if (lua_numbertointeger(ff, &fi))
      return fi < i;
    else
      return f < 0;
  }
}
/* f <= i  (LEfloatint): ceil(f) <= i */
static l_inline int titan_le_floatint(lua_Number f, lua_Integer i) {
  if (titan_intfitsf(i))
    return luai_numle(f, cast_num(i));
  else {
    lua_Integer fi;
    lua_Number ff = l_floor(f);
    if (ff != f)
      ff += 1; /* F2Iceil */
    if (lua_numbertointeger(ff, &fi))
      return fi <= i;
    else
      return f < 0;
  }
}
/* i == f  (luaV_equalobj int/float case, F2Ieq): equal iff f is integral,
** in range, and equals i. */
static l_inline int titan_eq_intfloat(lua_Integer i, lua_Number f) {
  lua_Integer fi;
  lua_Number ff = l_floor(f);
  if (ff != f)
    return 0; /* non-integral */
  if (!lua_numbertointeger(ff, &fi))
    return 0; /* out of range */
  return i == fi;
}

inline static TString *_integer2str(lua_State *L, lua_Integer i) {
  char _cvtbuff[LUA_N2SBUFFSZ];
  size_t len;
  len = (size_t)lua_integer2str(_cvtbuff, sizeof(_cvtbuff), i);
  return luaS_newlstr(L, _cvtbuff, len);
}

inline static TString *_float2str(lua_State *L, lua_Number f) {
  char _cvtbuff[LUA_N2SBUFFSZ];
  TValue _v;
  unsigned len;
  setfltvalue(&_v, f);
  len = luaO_tostringbuff(&_v, _cvtbuff);
  return luaS_newlstr(L, _cvtbuff, len);
}

/* Open the first occupied `<dir>/<file>` in this state's effective Titan path
** (then its lazy SDK fallback) lazily and globally; raises when it is absent
** or cannot be opened. Implemented in titan_path.c. */
TITAN_RUNTIME_FUNC void *loadlib(lua_State *L, const char *file);
TITAN_RUNTIME_FUNC void *loadsym(lua_State *L, void *lib, const char *sym);
typedef struct TitanModuleProvider {
  void *handle;
  TitanModuleSymbols symbols;
} TitanModuleProvider;

/* Immutable image-local catalog and archive anchors, published only in the
** launcher's state. Each entry has either a native resolver or a provider
** path relative to the runtime Titan search path. */
typedef struct TitanLinkedModule {
  const char *name;
  TitanModuleSymbols symbols;
  const char *provider;
} TitanLinkedModule;

typedef struct TitanLinkedModules {
  const TitanLinkedModule *begin;
  const TitanLinkedModule *end;
} TitanLinkedModules;

#define TITAN_LINKED_MODULES_KEY "Titan linked module providers"

/* Prefer initialized state, a matching native preload descriptor, and the
** launcher's private linked-module set, in that order, before opening a
** fallback image. A NULL file permits only the initialized canonical lookup;
** an empty file disables the caller's fallback. All successful lookups and
** checks preserve the Lua stack. */
TITAN_RUNTIME_FUNC TitanModuleProvider titan_module_provider(lua_State *L,
    const char *module, const char *file);
TITAN_RUNTIME_FUNC void *titan_module_symbol(lua_State *L,
    TitanModuleProvider provider, const char *sym);
TITAN_RUNTIME_FUNC void titan_check_module_abi(lua_State *L,
    TitanModuleProvider provider, const char *sym, const char *file);
TITAN_RUNTIME_FUNC void titan_check_module_compatibility(lua_State *L,
    TitanModuleProvider provider, const char *sym, const char *file,
    const char *verifier, size_t verifier_size);
/* Check one resolved ABI marker (`<m>_abi` on Unix, the plain-C
** `<m>_abi_value` query on Windows); raises unless it reports
** TITAN_ABI_VERSION. Implemented in titan_path.c. */
TITAN_RUNTIME_FUNC void titan_check_abi_entry(lua_State *L, void *raw,
    const char *sym, const char *file, const char *error);
TITAN_RUNTIME_FUNC void titan_invalidate_backtrace_state(lua_State *L);
/* Support-module members `_executable_dir`, `_compiler_root`, and
** `_expand_titan_path`, implemented in titan_path.c. */
TITAN_RUNTIME_FUNC int titan_path_lua_executable_dir(lua_State *L);
TITAN_RUNTIME_FUNC int titan_path_lua_compiler_root(lua_State *L);
TITAN_RUNTIME_FUNC int titan_path_lua_expand(lua_State *L);
/* Publish/recover one type-specific canonical pointer. The candidate is an
** opaque identity key and is never dereferenced. The helper preserves the Lua
** stack on success. */
TITAN_RUNTIME_FUNC const char *titan_publish_function_type_tag(lua_State *L,
                                                      const char *registry_key,
                                                      const char *candidate);

/*
** Dense Array runtime. A backing Table has no metatable, uses only its array
** part (with slot 0 reserved for the canonical Udata proxy and slots 1..N
** for elements), an empty hash part (nhsize = 0), and stores its logical
** length in lenhint. Mutable proxy uservalue 2 carries the generated
** type-directed Lua writer CClosure; const proxy uservalue 2 is nil.
*/
TITAN_RUNTIME_FUNC void titan_array_metatables(lua_State *L, Table **mutable_out,
                                      Table **const_out);
/* Read the already-initialized canonical pair without changing L->top. */
TITAN_RUNTIME_FUNC void titan_array_cached_metatables(lua_State *L, Table **mutable_out,
                                             Table **const_out);
TITAN_RUNTIME_FUNC Table *titan_array_metatable(lua_State *L);
static l_inline Table *titan_const_array_metatable(lua_State *L) {
  Table *mutable_metatable;
  Table *const_metatable;
  titan_array_metatables(L, &mutable_metatable, &const_metatable);
  cast_void(mutable_metatable);
  return const_metatable;
}

static l_inline lua_Unsigned titan_array_length(const Table *backing) {
  return *lenhint(backing);
}

static l_inline void titan_array_set_length(Table *backing,
                                            lua_Unsigned length) {
  *lenhint(backing) = cast_uint(length);
}

/* Implementation notes: doc/implementation/dense-arrays.md#structural-validation */
static l_inline Udata *titan_array_require_proxy(Table *backing) {
  lua_assert(backing != NULL && backing->asize > 0);
  lua_assert(*getArrTag(backing, 0) == ctb(LUA_VUSERDATA));
  return gco2u(getArrVal(backing, 0)->gc);
}

static l_inline Udata *titan_array_try_proxy(Table *backing, Table *metatable) {
  if (TITAN_LIKELY(backing->asize > 0)) {
    TValue value;
    arr2obj(backing, 0, &value);
    if (TITAN_LIKELY(ttisfulluserdata(&value))) {
      Udata *maybe_proxy = uvalue(&value);
      if (TITAN_LIKELY(maybe_proxy->metatable == metatable)) {
        return maybe_proxy;
      }
    }
  }
  return NULL;
}

/* Reject a null/collapsed tag pair before testing either exact identity. */
static l_inline Udata *titan_array_try_proxy_either(Table *backing,
                                                    Table *mutable_metatable,
                                                    Table *const_metatable) {
  Udata *proxy;
  if (mutable_metatable == NULL || const_metatable == NULL ||
      mutable_metatable == const_metatable)
    return NULL;
  proxy = titan_array_try_proxy(backing, mutable_metatable);
  return proxy != NULL ? proxy
                       : titan_array_try_proxy(backing, const_metatable);
}

static l_inline Table *titan_array_try_backing(const TValue *value,
                                               Table *metatable) {
  if (ttisfulluserdata(value)) {
    Udata *maybe_proxy = uvalue(value);
    if (TITAN_LIKELY(maybe_proxy->metatable == metatable)) {
      return hvalue(&maybe_proxy->uv[0].uv);
    }
  }
  return NULL;
}

static l_inline Table *titan_array_try_backing_either(const TValue *value,
                                                      Table *mutable_metatable,
                                                      Table *const_metatable) {
  if (mutable_metatable == NULL || const_metatable == NULL ||
      mutable_metatable == const_metatable)
    return NULL;
  if (ttisfulluserdata(value)) {
    Udata *maybe_proxy = uvalue(value);
    if (TITAN_LIKELY(maybe_proxy->metatable == mutable_metatable ||
                     maybe_proxy->metatable == const_metatable)) {
      return hvalue(&maybe_proxy->uv[0].uv);
    }
  }
  return NULL;
}

static l_inline Table *titan_array_require_backing(const TValue *value) {
  lua_assert(ttisfulluserdata(value));
  return hvalue(&uvalue(value)->uv[0].uv);
}

TITAN_RUNTIME_FUNC Table *titan_array_new_impl(lua_State *L, Table *metatable,
                                      lua_Unsigned capacity,
                                      const TValue *writer, int mutable,
                                      StkId result);

static l_inline Table *titan_array_new(lua_State *L, Table *metatable,
                                       lua_Unsigned capacity,
                                       const TValue *writer, StkId result) {
  return titan_array_new_impl(L, metatable, capacity, writer, 1, result);
}

static l_inline Table *titan_const_array_new(lua_State *L, Table *metatable,
                                             lua_Unsigned capacity,
                                             StkId result) {
  return titan_array_new_impl(L, metatable, capacity, NULL, 0, result);
}

TITAN_RUNTIME_FUNC Table *titan_array_shallow_copy(lua_State *L, Table *source,
                                          Table *mutable_metatable,
                                          Table *const_metatable, StkId result);
TITAN_RUNTIME_FUNC Table *titan_array_freeze(lua_State *L, Table *backing,
                                    Table *mutable_metatable,
                                    Table *const_metatable);
TITAN_RUNTIME_FUNC unsigned titan_array_growth(lua_State *L, lua_Unsigned index);
TITAN_RUNTIME_FUNC void titan_array_resize(lua_State *L, Table *backing,
                                  lua_Unsigned capacity);
TITAN_RUNTIME_FUNC lu_byte titan_array_get(Table *backing, lua_Integer index,
                                  TValue *result);
TITAN_RUNTIME_FUNC void titan_array_set_stack(lua_State *L, Table *backing,
                                     lua_Integer index, int value_index);

/* UCRT's printf family narrows long double to double on x86_64. Select the
** MinGW implementations explicitly without changing unrelated stdio policy. */
static l_inline int titan_reflect_format_long_double(char *buffer,
    size_t capacity, long double value) {
#ifdef __MINGW32__
  return __mingw_snprintf(buffer, capacity, "%La", value);
#else
  return snprintf(buffer, capacity, "%La", value);
#endif
}

static l_inline long double titan_reflect_parse_long_double(const char *text,
    char **end) {
#ifdef __MINGW32__
  /* MinGW's ordinary strtold is already an alias to this wide parser. */
  return __mingw_strtold(text, end);
#else
  return strtold(text, end);
#endif
}

/* Reflected native projections own ordinary const Arrays. The generated caller
** keeps every aggregate on the Lua stack until it is installed in its parent. */
static l_inline Table *titan_reflect_projection_array(lua_State *L,
                                                     lua_Unsigned count) {
  if (count > TITAN_ARRAY_MAX_CAPACITY)
    luaL_error(L, "native projection exceeds Titan Array capacity");
  Table *mt = titan_const_array_metatable(L);
  luaL_checkstack(L, 2, "reflection projection stack overflow");
  StkId result = L->top.p++;
  setnilvalue(s2v(result));
  Table *array = titan_const_array_new(L, mt, count, result);
  titan_array_set_length(array, count);
  setuvalue(L, s2v(L->top.p - 1), titan_array_require_proxy(array));
  return array;
}

static l_inline void titan_reflect_projection_put(lua_State *L, Table *array,
                                                  lua_Integer index) {
  TValue value = lua_totvalue(L, -1);
  obj2arr(array, cast_uint(index), &value);
  luaC_barrierback(L, obj2gco(array), &value);
  lua_pop(L, 1);
}

static l_inline Table *titan_reflect_projection_input(lua_State *L,
    const TValue *value, lua_Unsigned arity) {
  Table *mutable_mt, *const_mt;
  titan_array_cached_metatables(L, &mutable_mt, &const_mt);
  Table *array = titan_array_try_backing_either(value, mutable_mt, const_mt);
  if (array == NULL)
    luaL_error(L, "reflected construction requires an Array projection");
  /* Trailing nil positions have no Array length, but still have schema arity. */
  if (titan_array_length(array) > arity)
    luaL_error(L, "reflected construction has too many values");
  return array;
}

static l_inline Table *titan_ensure_metatables_table(lua_State *L) {
  luaL_checkstack(L, 1, "stack overflow creating metatables table");
  lua_getfield(L, LUA_REGISTRYINDEX, TITAN_METATABLES_KEY);
  TValue *v = s2v(L->top.p - 1);
  if (ttisnil(v)) {
    L->top.p--;
    lua_newtable(L);
    v = s2v(L->top.p - 1);
    lua_setfield(L, LUA_REGISTRYINDEX, TITAN_METATABLES_KEY);
  } else {
    L->top.p--;
  }
  return hvalue(v);
}

#endif
