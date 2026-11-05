#include "gate.h"
#include <lauxlib.h>
#include <emscripten.h>
#include <setjmp.h>
#include <stdint.h>
#include <stdlib.h>

/* Authored C frames deliberately remain live across Titan coroutine switches.
 * Volatile canaries and the post-call check prevent tail-call elimination. */
static unsigned int active_frames, peak_frames, waits, close_mask, bad_close;
static unsigned int close_counts[6];
static unsigned int lua_depth, callinfo_c_depth;

EM_ASYNC_JS(void, gate_timeout, (int milliseconds), {
  await new Promise(resolve => setTimeout(resolve, milliseconds));
});

static int bridge_frames(lua_State *L, int depth) {
  volatile uint32_t canary[16];
  int i;
  for (i = 0; i < 16; ++i) canary[i] = 0x71a90000U + depth * 31U + i;
  ++active_frames;
  if (active_frames > peak_frames) peak_frames = active_frames;
  if (depth) {
    bridge_frames(L, depth - 1);
  } else {
    lua_pushvalue(L, 1);
    lua_pushvalue(L, 2);
    lua_call(L, 1, 1);
  }
  for (i = 0; i < 16; ++i)
    if (canary[i] != 0x71a90000U + depth * 31U + i)
      luaL_error(L, "authored FFI stack canary changed");
  --active_frames;
  return 1;
}

int gate_bridge(lua_State *L) {
  lua_Debug frame;
  unsigned int lua_count = 0, c_count = 0;
  int level = 0;
  while (lua_getstack(L, level++, &frame)) {
    lua_getinfo(L, "S", &frame);
    if (frame.what[0] == 'C') ++c_count;
    else ++lua_count;
  }
  if (lua_count > lua_depth) lua_depth = lua_count;
  if (c_count > callinfo_c_depth) callinfo_c_depth = c_count;
  return bridge_frames(L, 3);
}
int gate_lua_depth(void) { return (int)lua_depth; }
int gate_callinfo_c_depth(void) { return (int)callinfo_c_depth; }

void gate_wait(int form, int milliseconds) {
  volatile uint32_t canary = 0x329abcdeU;
  ++waits;
  if (form == 0) emscripten_sleep(milliseconds);
  else gate_timeout(milliseconds);
  if (canary != 0x329abcdeU) abort();
}

double gate_now(void) { return emscripten_get_now(); }

void gate_busy(int milliseconds) {
  double until = emscripten_get_now() + milliseconds;
  while (emscripten_get_now() < until) { /* Deliberate negative control. */ }
}

void gate_close_event(int id) {
  if (id < 0 || id >= 6) { bad_close = 1; return; }
  if (++close_counts[id] != 1) bad_close = 1;
  close_mask |= 1U << id;
}

void gate_forbidden(void) { bad_close = 1; }
int gate_wait_count(void) { return (int)waits; }
int gate_frame_peak(void) { return (int)peak_frames; }

/* Shared guard refusal must precede even setjmp. The admitted path really
 * performs a nonlocal unwind, rather than returning a fixture constant. */
int titan_browser_gate_guarded(void) {
  jmp_buf target;
  if (!titan_browser_entry_allowed()) return -1;
  if (!setjmp(target)) longjmp(target, 1);
  return 1;
}

/* Observation is non-suspending and state-neutral, including after lua_close.
 * bits 0..7: live authored FFI frames, 8..13: close-defer identities,
 * bit 14: duplicate/forbidden continuation, 16..31: real outer wait count. */
unsigned int titan_browser_gate_observe(void) {
  return (active_frames > 255U ? 255U : active_frames) | (close_mask << 8) |
         (bad_close << 14) | ((waits & 65535U) << 16);
}
