#include "budget.h"
#include <lauxlib.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <minicoro.h>
#include "fixture_controls.h"

/* wasm-ld's main-stack bounds. */
extern unsigned char __stack_low, __stack_high;

/* The C stack bounds the factory installed with __set_stack_limits, the live
 * __stack_pointer and the two words at the installed low bound, read by the
 * host (fixture-imports.mjs). */
TITAN_WASM_IMPORT("budget_stack_state") void budget_stack_state(uint32_t state[5]);
enum { STACK_LOW, STACK_HIGH, STACK_POINTER, STACK_COOKIE, STACK_COOKIE_HIGH };
/* The cookie the factory keeps at a coroutine stack's low end. */
#define BUDGET_COOKIE 0x02135467U
#define BUDGET_COOKIE_HIGH 0x89bacdfeU

static volatile uint32_t seed = 0x329U, sink;
static int fail_create, failed_allocator;
static int bridge_depth;
static unsigned int last_stack_span, last_stack_free;
extern mco_result __real_mco_create(mco_coro **out, mco_desc *desc);
mco_result __wrap_mco_create(mco_coro **out, mco_desc *desc) {
  mco_result result;
  if (fail_create) {
    fail_create = 0;
    *out = NULL;
    failed_allocator = 1;
    return MCO_OUT_OF_MEMORY;
  }
  result = __real_mco_create(out, desc);
  if (result == MCO_OUT_OF_MEMORY) failed_allocator = 1;
  return result;
}
void budget_fail_next_create(void) { fail_create = 1; }
void budget_reset_failure(void) { failed_allocator = 0; }
int budget_failed_allocator(void) { return failed_allocator; }
unsigned int budget_heap_size(void) { return (unsigned int)__builtin_wasm_memory_size(0) * 65536U; }
/* The image's -Wl,--max-memory. */
unsigned int budget_heap_max(void) { return 2147483648U; }
unsigned int budget_last_stack_span(void) { return last_stack_span; }
unsigned int budget_last_stack_free(void) { return last_stack_free; }
void budget_wait(void) { fixture_sleep(1); }

/* Titan's coroutines run on per-state minicoro runtimes, which mco_running()
 * does not report; the installed bounds name the running stack. Main runs on
 * wasm-ld's stack, and each coroutine on its own allocation above it. */
static int budget_on_main(const uint32_t state[5]) {
  return state[STACK_LOW] == (uintptr_t)&__stack_low;
}
/* The installed bounds hold the live stack pointer: exactly wasm-ld's stack
 * on main, an allocation above it in a coroutine. */
static void budget_installed_stack(uint32_t state[5]) {
  budget_stack_state(state);
  if (state[STACK_POINTER] < state[STACK_LOW] || state[STACK_POINTER] >= state[STACK_HIGH]) abort();
  if (budget_on_main(state) ? state[STACK_HIGH] != (uintptr_t)&__stack_high :
      state[STACK_LOW] < (uintptr_t)&__stack_high) abort();
}
static unsigned int budget_stack_free(void) {
  uint32_t state[5];
  budget_installed_stack(state);
  return state[STACK_POINTER] - state[STACK_LOW];
}
/* `frame` is live on the installed stack, at or above the stack pointer. */
static void budget_record_stack(const void *frame) {
  uint32_t state[5];
  budget_installed_stack(state);
  if ((uintptr_t)frame < state[STACK_POINTER] || (uintptr_t)frame >= state[STACK_HIGH]) abort();
  last_stack_span = state[STACK_HIGH] - state[STACK_LOW];
  last_stack_free = state[STACK_POINTER] - state[STACK_LOW];
}

/* D2: under --stack-first the main stack ends at address 0, where an overflow
 * already traps, so the factory neither writes nor checks a cookie there. A
 * coroutine stack's low end holds the cookie the factory checks whenever the
 * coroutine switches away or resumes. */
int budget_cookie_main(void) {
  uint32_t state[5];
  budget_installed_stack(state);
  return budget_on_main(state) && state[STACK_LOW] == 0 &&
    !(state[STACK_COOKIE] == BUDGET_COOKIE && state[STACK_COOKIE_HIGH] == BUDGET_COOKIE_HIGH);
}
int budget_cookie_coroutine(void) {
  uint32_t state[5];
  budget_installed_stack(state);
  return !budget_on_main(state) &&
    state[STACK_COOKIE] == BUDGET_COOKIE && state[STACK_COOKIE_HIGH] == BUDGET_COOKIE_HIGH;
}
/* Overwrite the running coroutine's cookie without overflowing: the factory
 * aborts when the coroutine next switches away. */
void budget_overwrite_cookie(void) {
  uint32_t state[5];
  budget_installed_stack(state);
  if (budget_on_main(state)) abort();
  *(volatile uint32_t *)(uintptr_t)state[STACK_LOW] = ~BUDGET_COOKIE;
}

/* Fixed live C frames exercise wasm-opt's checked function-prologue stack
 * allocation, not arbitrary unsafe dynamic alloca. The separate-TU canary
 * check preserves the full frame and prevents tail recursion. */
__attribute__((noinline)) static int budget_shadow_tail(int bytes) {
  unsigned int area[4];
  area[0] = (unsigned int)bytes;
  area[3] = (unsigned int)bytes ^ 0x329U;
  if (bytes > 16) {
    if (budget_shadow_tail(bytes - 16) != 91) abort();
  } else {
    budget_record_stack(area);
  }
  if (!budget_check_tail(area, (unsigned int)bytes)) abort();
  return 91;
}

__attribute__((noinline)) static int budget_shadow_frame256(int bytes) {
  unsigned int area[64];
  area[0] = (unsigned int)bytes;
  area[63] = (unsigned int)bytes ^ 0x329U;
  if (bytes >= 512) {
    if (budget_shadow_frame256(bytes - 256) != 91) abort();
  } else if (bytes > 256) {
    if (budget_shadow_tail(bytes - 256) != 91) abort();
  } else {
    budget_record_stack(area);
  }
  if (!budget_check_pad(area, (unsigned int)bytes)) abort();
  return 91;
}

__attribute__((noinline)) int budget_shadow_bytes(int bytes) {
  if (bytes <= 0 || (bytes & 15) != 0) abort();
  return bytes >= 256 ? budget_shadow_frame256(bytes) : budget_shadow_tail(bytes);
}

/* Distinct volatile reads/writes keep 32 actual Wasm locals live across a
 * recursive call and JSPI suspension, separately from the linear C stack. */
#define EACH(X) X(0) X(1) X(2) X(3) X(4) X(5) X(6) X(7) \
 X(8) X(9) X(10) X(11) X(12) X(13) X(14) X(15) \
 X(16) X(17) X(18) X(19) X(20) X(21) X(22) X(23) \
 X(24) X(25) X(26) X(27) X(28) X(29) X(30) X(31)
__attribute__((noinline)) static int deep(lua_State *L, int depth) {
  uint32_t expected = seed + (uint32_t)depth;
#define DECL(i) uint32_t v##i = seed + (uint32_t)depth + i;
  EACH(DECL)
#undef DECL
  if (depth) deep(L, depth - 1);
  else {
    ++seed;
    lua_pushvalue(L, 1);
    printf("BUDGET MIXED c_depth=%d shadow_free=%u wasm_register_canaries=32\n",
        bridge_depth, budget_stack_free());
    fflush(stdout);
    lua_call(L, 0, 0);
  }
#define CHECK(i) sink = v##i; if (v##i != expected + i) return luaL_error(L, "Wasm register canary changed");
  EACH(CHECK)
#undef CHECK
  return 0;
}
int budget_bridge(lua_State *L) {
  bridge_depth = (int)luaL_checkinteger(L, 2);
  return deep(L, bridge_depth);
}

int budget_load_mixed(lua_State *L) {
  static const char source[] =
    "local function frames(n, bridge, body, depth)\n"
    " local canary = {n, 'mixed-budget'}\n"
    " if n == 0 then bridge(body, depth) else frames(n-1, bridge, body, depth) end\n"
    " assert(canary[1] == n and canary[2] == 'mixed-budget')\n"
    "end\n"
    "return function(bridge, body, depth) frames(4, bridge, body, depth) end\n";
  return luaL_loadbuffer(L, source, sizeof(source) - 1, "@budget-mixed.lua");
}
int budget_load_lua_limit(lua_State *L) {
  static const char source[] =
    "local function recurse(n)\n"
    " if n == 0 then return 0 end\n"
    " local ok, result = pcall(recurse, n-1)\n"
    " if not ok then error(result, 0) end\n"
    " return result+1\n"
    "end\n"
    "local ok, message = pcall(recurse, 10000)\n"
    "assert(not ok and tostring(message):find('C stack overflow', 1, true), tostring(message))\n"
    "return message\n";
  return luaL_loadbuffer(L, source, sizeof(source) - 1, "@budget-lua.lua");
}

