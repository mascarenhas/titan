#ifndef TITAN_BROWSER_GATE_H
#define TITAN_BROWSER_GATE_H
#include <stdint.h>
#include <titan/browser.h>
#include "fixture_controls.h"
int titan_browser_gate_guarded(uint64_t operation_id);
void gate_lifetime_operation(lua_State *L, int requested_phase);
int gate_lifetime_is_child(lua_State *L);
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
