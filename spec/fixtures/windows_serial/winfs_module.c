/* Optional native test module; not part of the Titan runtime build. */
#include "lua.h"
#include "lauxlib.h"
#include "../../../titan-runtime/ltitan_winmeta.h"
#include "../../../titan-runtime/ltitan_wintool.h"

static const luaL_Reg functions[] = {
  { "_win_tmpname", titan_winfs_tmpname },
  { "_win_reserve_sibling", titan_winfs_reserve_sibling },
  { "_win_replace", titan_winfs_replace },
  { "_win_stat", titan_winfs_stat },
  { "_win_realpath", titan_winfs_realpath },
  { "_win_abspath", titan_winfs_abspath },
  { "_win_resolve_executable", titan_winfs_resolve_executable },
  { NULL, NULL }
};

__declspec(dllexport) int luaopen_winfs_test(lua_State *L) {
  luaL_newlib(L, functions);
  return 1;
}
