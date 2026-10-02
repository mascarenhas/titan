/* Header-only COFF ownership probe: no Windows SDK or link step is needed. */
#ifdef __cplusplus
extern "C" {
#endif
#include "lua.h"
#include "lualib.h"
#include "lctype.h"
#include "lopcodes.h"
/* ltm.h only needs this opaque pointer type from lstate.h. */
typedef struct CallInfo CallInfo;
#include "ltm.h"
#ifdef __cplusplus
}
#endif

LUAMOD_API int luaopen_titan_annotation_probe(lua_State *L) {
    unsigned int index = (unsigned int)lua_gettop(L);
    return luaopen_base(L) + luaO_ceillog2(index) +
        lua_ident[index] + luai_ctype_[index] + luaP_opmodes[index] +
        (luaT_typenames_[index] != 0);
}
