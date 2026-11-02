#ifndef TITAN_BROWSER_TRACE_NAMES_FIXTURE_H
#define TITAN_BROWSER_TRACE_NAMES_FIXTURE_H
#include "lua.h"
int trace_names_resolves(lua_State *L, const char *symbol, const char *expected);
#endif
