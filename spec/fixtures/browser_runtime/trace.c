#include "trace.h"
#include <lauxlib.h>
#include <string.h>

int browser_trace_load_shape(lua_State *L) {
  static const char source[] =
    "local function middle(action)\n"
    "  action()\n"
    "end\n"
    "local function tail(action) return middle(action) end\n"
    "return function(action)\n"
    "  local result = tail(action)\n"
    "  return result\n"
    "end\n";
  return luaL_loadbuffer(L, source, sizeof(source) - 1, "@browser-trace.lua");
}

int browser_trace_load_pin(lua_State *L) {
  static const char source[] =
    "return function(fail, reraiser)\n"
    "  local support = require 'titan'\n"
    "  local ok, payload = pcall(fail)\n"
    "  assert(not ok and payload == 'trace-original')\n"
    "  local original = support.backtrace()\n"
    "  assert(type(original) == 'string' and #original > 0)\n"
    "  support.pin()\n"
    "  local again, raised = pcall(reraiser, payload)\n"
    "  assert(not again and raised == payload)\n"
    "  assert(support.backtrace() == original, 'pin did not preserve trace')\n"
    "  local fresh, changed = pcall(reraiser, 'trace-fresh')\n"
    "  assert(not fresh and changed == 'trace-fresh')\n"
    "  assert(support.backtrace() ~= original, 'one-shot pin survived fresh raise')\n"
    "  support.clear()\n"
    "  assert(support.backtrace() == nil, 'clear retained trace')\n"
    "end\n";
  return luaL_loadbuffer(L, source, sizeof(source) - 1, "@browser-pin.lua");
}

int browser_trace_load_resume(lua_State *L) {
  static const char source[] = "return function(action)\n  action()\nend\n";
  return luaL_loadbuffer(L, source, sizeof(source) - 1, "@browser-resume.lua");
}
