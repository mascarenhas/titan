#ifndef TITAN_BROWSER_RUNTIME_TRACE_FIXTURE_H
#define TITAN_BROWSER_RUNTIME_TRACE_FIXTURE_H
#include <lua.h>
#include "../browser_trace/trace_frame_lines.h"
int browser_trace_load_shape(lua_State *L);
int browser_trace_load_pin(lua_State *L);
int browser_trace_load_resume(lua_State *L);
#endif
