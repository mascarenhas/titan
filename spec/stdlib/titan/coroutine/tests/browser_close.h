#ifndef TITAN_SPEC_BROWSER_CLOSE_H
#define TITAN_SPEC_BROWSER_CLOSE_H
#include <lua.h>
int browser_close_probe(lua_State *parent);
void browser_close_record(int event);
#endif
