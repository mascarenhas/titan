-- Fixed C translation-unit prefix shared by generated modules and compiler
-- probes. Foreign imports are emitted immediately after this block in both
-- places, so the configured headers see the same Lua/Titan declarations and
-- macro state during validation and production compilation.
local cpreamble = {}

cpreamble.fixed_includes = [[#include <stdlib.h>
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

static inline int titan_errfunc_is_errorhandler(lua_State *L) {
    if (L->errfunc == 0) return 0;
    StkId errfunc = restorestack(L, L->errfunc);
    TValue *v = s2v(errfunc);
    return ttislcf(v) && fvalue(v) == errorhandler;
}]]

cpreamble.after_foreign_imports = [[#ifdef __clang__
#pragma clang diagnostic ignored "-Wunused-function"
#pragma clang diagnostic ignored "-Wparentheses-equality"
#endif]]

return cpreamble
