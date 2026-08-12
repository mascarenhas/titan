-- Fixed C translation-unit prefix shared by generated modules and compiler
-- probes. Foreign imports are emitted immediately after this block in both
-- places, so the configured headers see the same Lua/Titan declarations and
-- macro state during validation and production compilation.
local cpreamble = {}

cpreamble.fixed_includes = [[#include <stdlib.h>
#include <stddef.h>
#include <string.h>
#include <math.h>

#include "luaconf.h"
#include "lauxlib.h"
#include "lstate.h"
#include "lgc.h"
#include "ltable.h"
#include "ltm.h"
#include "lfunc.h"
#include "lstring.h"
#include "lvm.h"
#include "lobject.h"
#include "ldo.h"

#include "titan.h"]]

cpreamble.fixed_prefix = cpreamble.fixed_includes .. [[

static TITAN_UNUSED inline int titan_errfunc_is_errorhandler(lua_State *L) {
    if (L->errfunc == 0) return 0;
    StkId errfunc = restorestack(L, L->errfunc);
    TValue *v = s2v(errfunc);
    return ttislcf(v) && fvalue(v) == errorhandler;
}

/*
 * Generated code frequently reserves stack slots before writing through
 * L->top.p directly. lua_checkstack reports an exhausted stack by returning
 * false; continuing after that result would write outside the live stack.
 * Keep every ordinary generated reservation on this one raising path.
*/
static TITAN_UNUSED inline void titan_ensure_stack(lua_State *L, int slots) {
    if (TITAN_UNLIKELY(!lua_checkstack(L, slots)))
        luaL_error(L, "stack overflow in Titan generated code");
}]]

cpreamble.after_foreign_imports = [[#if defined(__GNUC__) || defined(__clang__)
#define TITAN_SOURCE_LOCAL __attribute__((visibility("hidden")))
#else
#define TITAN_SOURCE_LOCAL
#endif

#ifdef __clang__
#pragma clang diagnostic ignored "-Wunused-function"
#pragma clang diagnostic ignored "-Wparentheses-equality"
#endif]]

return cpreamble
