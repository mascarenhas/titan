#ifndef TITAN_BROWSER_GATE_H
#define TITAN_BROWSER_GATE_H
#include <lua.h>
int titan_browser_entry_allowed(void);
int titan_browser_gate_guarded(void);
unsigned int titan_browser_gate_observe(void);
int gate_bridge(lua_State *L);
void gate_wait(int form, int milliseconds);
double gate_now(void);
void gate_busy(int milliseconds);
void gate_close_event(int id);
void gate_forbidden(void);
int gate_wait_count(void);
int gate_frame_peak(void);
int gate_lua_depth(void);
int gate_callinfo_c_depth(void);
#endif
