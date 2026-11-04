#ifndef TITAN_JSON_NATIVE_H
#define TITAN_JSON_NATIVE_H

#include <lua.h>

/* Native max_depth accepts every positive Titan integer. */
#ifndef TITAN_JSON_WRITER_DEPTH_LIMIT
#define TITAN_JSON_WRITER_DEPTH_LIMIT LUA_MAXINTEGER
#endif

#endif
