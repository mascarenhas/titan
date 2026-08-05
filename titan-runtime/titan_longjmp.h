#ifndef TITAN_LONGJMP_H
#define TITAN_LONGJMP_H

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

#include <setjmp.h>

#include "llimits.h"   /* TStatus, l_uint32 */

/* --- BEGIN verbatim from lua-5.5.1/src/ldo.c:61-65 --- */

/* chained list of long jump buffers */
typedef struct lua_longjmp {
  struct lua_longjmp *previous;
  jmp_buf b;
  volatile TStatus status;  /* error code */
} lua_longjmp;

/* --- END verbatim --- */

/*
** Statement-form setjmp selector, mirroring the upstream LUAI_THROW/LUAI_TRY
** #ifdef ladder (lua-5.5.1/src/ldo.c:74-107) but expressed as a value usable in
** an `if (TITAN_SETJMP(buf) == 0) { ... }` boundary (the upstream LUAI_TRY is
** function-form and takes a Pfunc; we cannot use it for inline straight-line C).
** The same selection (_setjmp on POSIX, setjmp otherwise) keeps the buffer
** read/written by the same routine the linked liblua.a uses for LUAI_THROW.
*/
#if defined(LUA_USE_POSIX)
#define TITAN_SETJMP(buf)  _setjmp(buf)
#else
#define TITAN_SETJMP(buf)  setjmp(buf)
#endif

#endif /* TITAN_LONGJMP_H */
