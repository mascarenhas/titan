#ifndef TITAN_TRACE_FIXTURE_SUPPORT_H
#define TITAN_TRACE_FIXTURE_SUPPORT_H
#include <lua.h>
#include <stddef.h>
#include "trace_frame_lines.h"
int trace_fixture_load(lua_State *L, int which);
int trace_fixture_bridge(lua_State *L);
int trace_fixture_backtrace(lua_State *L);
int trace_fixture_cleared(lua_State *L);
int trace_fixture_states(lua_State *L, int close_retained);
int trace_fixture_allocation(lua_State *L, int nested);
void trace_fixture_record(int event);
void trace_fixture_emit(const char *label, const char *trace);
int trace_fixture_count(const char *text, const char *needle);
int trace_fixture_order(const char *text, const char *first, const char *second);
void trace_fixture_sleep(void);
void trace_fixture_host_recover(void);
void trace_fixture_handler(lua_State *L);
int trace_fixture_ordinary_truncation(const char *trace, const char *marker);
int trace_fixture_host_absent_limit(void);
#endif
