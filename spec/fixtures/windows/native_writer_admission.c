#include <windows.h>
#include "lua.h"
#include "lauxlib.h"

#define WRITER_OBSERVER "TitanNativeWriterObserver"

typedef struct WriterObserver {
  HANDLE process;
} WriterObserver;

static int observer_close(lua_State *L) {
  WriterObserver *observer = (WriterObserver *)luaL_checkudata(L, 1, WRITER_OBSERVER);
  if (observer->process != NULL) CloseHandle(observer->process);
  observer->process = NULL;
  return 0;
}

/* One zero-time query on a pinned process object, not a PID lookup or wait. */
static int observer_dead(lua_State *L) {
  WriterObserver *observer = (WriterObserver *)luaL_checkudata(L, 1, WRITER_OBSERVER);
  DWORD result;
  luaL_argcheck(L, observer->process != NULL, 1, "closed writer observer");
  result = WaitForSingleObject(observer->process, 0);
  if (result != WAIT_OBJECT_0 && result != WAIT_TIMEOUT)
    return luaL_error(L, "cannot query writer process: Windows error %d",
                      (int)GetLastError());
  lua_pushboolean(L, result == WAIT_OBJECT_0);
  return 1;
}

static int observer_watch(lua_State *L) {
  lua_Integer pid = luaL_checkinteger(L, 1);
  WriterObserver *observer;
  luaL_argcheck(L, pid > 0 && (lua_Unsigned)pid <= MAXDWORD, 1, "invalid writer PID");
  observer = (WriterObserver *)lua_newuserdatauv(L, sizeof *observer, 0);
  observer->process = NULL;
  luaL_setmetatable(L, WRITER_OBSERVER);
  observer->process = OpenProcess(SYNCHRONIZE, FALSE, (DWORD)pid);
  if (observer->process == NULL)
    return luaL_error(L, "cannot observe live writer: Windows error %d",
                      (int)GetLastError());
  return 1;
}

__declspec(dllexport) int luaopen_native_writer_admission(lua_State *L) {
  if (luaL_newmetatable(L, WRITER_OBSERVER)) {
    lua_pushcfunction(L, observer_close); lua_setfield(L, -2, "__gc");
    lua_pushcfunction(L, observer_dead); lua_setfield(L, -2, "dead");
    lua_pushvalue(L, -1); lua_setfield(L, -2, "__index");
  }
  lua_pop(L, 1);
  lua_newtable(L);
  lua_pushcfunction(L, observer_watch); lua_setfield(L, -2, "watch");
  return 1;
}
