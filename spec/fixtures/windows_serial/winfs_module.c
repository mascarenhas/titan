/* Optional native test module; not part of the Titan runtime build. */
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0602
#endif
#include "lua.h"
#include "lauxlib.h"
#include "../../../titan-runtime/ltitan_winmeta.h"
#include "../../../titan-runtime/ltitan_wintool.h"
#include "../../../titan-runtime/ltitan_winprocess.h"

static const luaL_Reg functions[] = {
  { "_win_tmpname", titan_winfs_tmpname },
  { "_win_reserve_sibling", titan_winfs_reserve_sibling },
  { "_win_replace", titan_winfs_replace },
  { "_win_stat", titan_winfs_stat },
  { "_win_realpath", titan_winfs_realpath },
  { "_win_abspath", titan_winfs_abspath },
  { "_win_resolve_executable", titan_winfs_resolve_executable },
  { "_win_compile_new", titan_winprocess_new },
  { "_win_compile_spawn", titan_winprocess_spawn },
  { "_win_compile_wait", titan_winprocess_wait },
  { "_win_compile_finish", titan_winprocess_finish },
  { "_win_compile_close", titan_winprocess_close },
  { NULL, NULL }
};

__declspec(dllexport) int luaopen_winfs_test(lua_State *L) {
  luaL_newlib(L, functions);
  return 1;
}
