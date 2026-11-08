#include "trace_support.h"
#include <lauxlib.h>
#include <lualib.h>
#include <titan/ffi.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef __EMSCRIPTEN__
#include <emscripten.h>
EM_JS(void, trace_fixture_publish_controls, (void), {
  const publish = Module['titanBrowserBridge'].options.bindings?.__traceTest;
  if (!publish) return;
  publish(Object.freeze({
    metadata: () => {
      const value = Module['titanBrowserTrace'];
      return Object.freeze({state: value.state, reason: value.reason, mapBytes: value.mapBytes,
        indexBytes: value.indexBytes, loadMilliseconds: value.loadMilliseconds});
    },
  }));
});
__attribute__((constructor)) static void trace_fixture_constructor(void) {
  trace_fixture_publish_controls();
}
#endif

static const char mixed_source[] =
  "local function lua_inner(action, c)\n"
  "  c.bridge(action)\n"
  "end\n"
  "local function lua_outer(apply, action, c)\n"
  "  apply(function() lua_inner(action, c) end)\n"
  "end\n"
  "return function(apply, action, bridge)\n"
  "  local c = {bridge = bridge}\n"
  "  apply(function() lua_outer(apply, action, c) end)\n"
  "end\n";
static const char tail_source[] =
  "local function middle(action)\n  action()\nend\n"
  "local function tail(action) return middle(action) end\n"
  "return function(action)\n  local result = tail(action)\n  return result\nend\n";
static const char shape_source[] = "return function(action)\n  action()\nend\n";
/* #343 Scope G: the nested-protected-call construct the browser C-call limit is
 * sized against, at exactly one `getCcalls` count per level (`pcall` is the
 * only C boundary on the path). `bound` is supplied by the caller so it can sit
 * above the limit and below every engine's stack ceiling; reaching it raises
 * the caller's own action, which is how a missing limit shows up as an
 * assertion instead of an engine failure. The error is re-raised unchanged so
 * the caller sees Lua's own message. */
static const char pcall_source[] =
  "return function(apply, bound)\n"
  "  local function descend(n)\n"
  "    if n == 0 then return apply() end\n"
  "    local ok, err = pcall(descend, n - 1)\n"
  "    if not ok then error(err, 0) end\n"
  "  end\n"
  "  descend(bound)\n"
  "end\n";
static const char method_source[] = "return function(receiver)\n  receiver:fail()\nend\n";
static const char fallback_source[] =
  "local function descend(n, action)\n"
  "  if n == 0 then action(); return end\n"
  "  descend(n-1, action)\n"
  "  return n\n"
  "end\n"
  "return function(action)\n"
  "  descend(600, action)\n"
  "end\n";
static const char pin_source[] =
  "return function(fail, reraiser)\n"
  "  local support = require 'titan'\n"
  "  local ok, payload = pcall(fail); assert(not ok and payload == 'trace-original')\n"
  "  local original = support.backtrace()\n"
  "  assert(type(original) == 'string' and original:find('in trace_cases.original_leaf', 1, true))\n"
  "  support.pin()\n"
  "  ok, payload = pcall(reraiser, 'trace-original')\n"
  "  assert(not ok and payload == 'trace-original')\n"
  "  assert(support.backtrace() == original, 'one-shot pin changed original trace')\n"
  "  ok, payload = pcall(reraiser, 'trace-original')\n"
  "  assert(not ok and payload == 'trace-original')\n"
  "  local fresh = support.backtrace()\n"
  "  assert(fresh ~= original and fresh:find('in trace_cases.reraiser', 1, true))\n"
  "  assert(not fresh:find('in trace_cases.original_leaf', 1, true))\n"
  "  support.clear()\n"
  "  assert(support.backtrace() == nil, 'public clear retained trace')\n"
  "end\n";

int trace_fixture_load(lua_State *L, int which) {
  const char *source, *name;
  if (which == 0) { source = mixed_source; name = "@trace-mixed.lua"; }
  else if (which == 1) { source = tail_source; name = "@trace-tail.lua"; }
  else if (which == 3) { source = pin_source; name = "@trace-pin.lua"; }
  else if (which == 7) { source = pcall_source; name = "@trace-pcall.lua"; }
  else if (which == 5) { source = method_source; name = "@trace-method.lua"; }
  else if (which == 6) { source = fallback_source; name = "@trace-fallback.lua"; }
  else { source = shape_source; name = which == 4 ? "@trace-resume.lua" : "@trace-shape.lua"; }
  return luaL_loadbuffer(L, source, strlen(source), name);
}

/* nodebug deliberately leaves a genuine Lua C function adjacent to the
 * debug-bearing Titan closure. Its Lua CallInfo must not borrow Titan lines. */
#if defined(__clang__)
__attribute__((noinline, nodebug))
#endif
int trace_fixture_bridge(lua_State *L) {
  luaL_checktype(L, 1, LUA_TFUNCTION);
  lua_settop(L, 1);
  lua_call(L, 0, 0);
  return 0;
}

int trace_fixture_count(const char *text, const char *needle) {
  int count = 0;
  size_t length = strlen(needle);
  if (!length) return 0;
  while ((text = strstr(text, needle)) != NULL) { ++count; text += length; }
  return count;
}
int trace_fixture_order(const char *text, const char *first, const char *second) {
  const char *a = strstr(text, first);
  return a && strstr(a + strlen(first), second) != NULL;
}

/* The independent capturing state has loaded trace_cases/test, not the parent
 * synthetic runner. D15 preserves these two parent's raw-symbol fallbacks. */
static int parent_runner_frame(const char *trace, int line, const char *suffix) {
  char expected[256];
  const char *found;
  snprintf(expected, sizeof expected, "trace_cases__test_runner.titan:%d%s", line, suffix);
  found = strstr(trace, expected);
  if (!found) {
    snprintf(expected, sizeof expected, "trace_cases__test_runner.titan%s", suffix);
    found = strstr(trace, expected);
  }
  return found && (found == trace || found[-1] == '\n') &&
    (found[strlen(expected)] == '\0' || found[strlen(expected)] == '\n') &&
    trace_fixture_count_frame_lines(trace, suffix) == 1;
}
void trace_fixture_emit(const char *label, const char *trace) {
  printf("TRACE-BEGIN %s\n%s\nTRACE-END %s\n", label, trace, label);
  fflush(stdout);
}
void trace_fixture_sleep(void) {
#ifdef __EMSCRIPTEN__
  emscripten_sleep(1);
#endif
}

#ifdef __EMSCRIPTEN__
/* Test-owned host bridge, called only after the failed catch has completed. */
EM_JS(void, trace_fixture_host_recover, (void), {
  Module['titanBrowserBridge'].options.bindings.traceFixtureRestoreDescriptors();
});
#else
void trace_fixture_host_recover(void) {}
#endif

/* One-result public backtrace access, not a read of the private registry slot.
 * The returned value remains on the caller's Lua stack. */
int trace_fixture_backtrace(lua_State *L) {
  lua_getglobal(L, "require"); lua_pushliteral(L, "titan"); lua_call(L, 1, 1);
  lua_getfield(L, -1, "backtrace"); lua_call(L, 0, 1);
  lua_remove(L, -2);
  return 1;
}
int trace_fixture_cleared(lua_State *L) {
  int top = lua_gettop(L), clear;
  trace_fixture_backtrace(L);
  clear = lua_isnil(L, -1);
  lua_settop(L, top);
  return clear;
}

static int close_counts[3];
void trace_fixture_record(int event) {
  if (event >= 0 && event < 3) ++close_counts[event];
}
static void copy_preloads(lua_State *parent, lua_State *child) {
  lua_getfield(parent, LUA_REGISTRYINDEX, LUA_PRELOAD_TABLE);
  lua_pushnil(parent);
  while (lua_next(parent, -2)) {
    if (lua_type(parent, -2) == LUA_TSTRING && lua_iscfunction(parent, -1)) {
      size_t length;
      const char *name = lua_tolstring(parent, -2, &length);
      lua_CFunction loader = lua_tocfunction(parent, -1);
      TitanModuleSymbols symbols = titan_module_preload_symbols(parent, name, length, loader);
      titan_module_preload(child, name, length, loader, symbols);
    }
    lua_pop(parent, 1);
  }
  lua_pop(parent, 1);
}
static int state_setup(lua_State *child) {
  lua_State *parent = lua_touserdata(child, 1);
  luaL_openlibs(child);
  titan_install_searcher(child);
  copy_preloads(parent, child);
  lua_getglobal(child, "require"); lua_pushliteral(child, "trace_cases"); lua_call(child, 1, 1);
  lua_getglobal(child, "require"); lua_pushliteral(child, "titan"); lua_call(child, 1, 1);
  return 0;
}
static lua_State *new_state(lua_State *parent) {
  int top = lua_gettop(parent), status;
  lua_State *child = luaL_newstate();
  if (!child) luaL_error(parent, "cannot create trace fixture Lua state");
  lua_pushcfunction(child, state_setup); lua_pushlightuserdata(child, parent);
  status = lua_pcall(child, 1, 0, 0);
  lua_settop(parent, top);
  if (status != LUA_OK) {
    char message[512];
    snprintf(message, sizeof message, "%s", lua_tostring(child, -1));
    lua_close(child);
    luaL_error(parent, "trace state initialization failed: %s", message);
  }
  return child;
}
static int state_scenario(lua_State *L) {
  const char *source = lua_tostring(L, 1);
  luaL_loadstring(L, source); lua_call(L, 0, 0);
  return 0;
}
static int scenario(lua_State *L, const char *source) {
  lua_pushcfunction(L, state_scenario); lua_pushstring(L, source);
  return lua_pcall(L, 1, 0, 0);
}
int trace_fixture_states(lua_State *parent, int close_retained) {
  int ok, top = lua_gettop(parent);
  lua_State *first, *second;
  if (!lua_checkstack(parent, 8)) return luaL_error(parent, "cannot reserve preload snapshot stack");
  first = new_state(parent);
  second = new_state(parent);
  memset(close_counts, 0, sizeof close_counts);
  if (close_retained) {
    ok = scenario(first, "require('trace_cases').retain_for_state_close()") == LUA_OK;
  } else {
    ok = scenario(first,
      "local m,s=require('trace_cases'),require('titan'); local ok,e=pcall(m.reraiser,'state-first'); assert(not ok and e=='state-first'); local t=s.backtrace(); assert(t:find('in trace_cases.reraiser',1,true)); saved_trace=t; s.pin()") == LUA_OK;
    ok = ok && scenario(second,
      "local m,s=require('trace_cases'),require('titan'); assert(s.backtrace()==nil); local ok,e=pcall(m.reraiser,'state-second'); assert(not ok and e=='state-second'); assert(s.backtrace():find('in trace_cases.reraiser',1,true)); s.clear(); assert(s.backtrace()==nil)") == LUA_OK;
    ok = ok && scenario(first,
      "local m,s=require('trace_cases'),require('titan'); assert(s.backtrace()==saved_trace); local ok,e=pcall(m.reraiser,'state-third'); assert(not ok and e=='state-third'); assert(s.backtrace()==saved_trace)") == LUA_OK;
  }
  lua_close(first);
  if (close_retained) ok = ok && close_counts[0] == 1 && close_counts[1] == 1 && close_counts[2] == 0;
  ok = ok && scenario(second,
    "local m,s=require('trace_cases'),require('titan'); s.clear(); local ok,e=pcall(m.reraiser,'after-state-close'); assert(not ok and e=='after-state-close'); assert(s.backtrace():find('in trace_cases.reraiser',1,true))") == LUA_OK;
  lua_close(second);
  lua_settop(parent, top);
  return ok ? 2 : -1;
}

/* The allocator targets the first luaL_Buffer spill, not raise preparation or
 * stack growth. UBox is two C words in this pinned Lua. Its userdata allocation
 * uses Lua's retry path and throws LUA_ERRMEM; raw resizebox NULL instead throws
 * LUA_ERRRUN, and is therefore used only for the nested-capture callback. */
typedef struct {
  lua_Alloc original;
  void *data;
  lua_State *nested;
  int mode, armed, hits, nested_status;
  size_t watched_allocations;
} Allocation;
static void direct_handler(lua_State *L, void *data) {
  (void)data;
  errorhandler(L);
}
static int protected_handler(lua_State *L) {
  CallInfo *ci = L->ci;
  lu_byte allowhook = L->allowhook;
  ptrdiff_t errfunc = L->errfunc;
  ptrdiff_t top = savestack(L, L->top.p);
  int status = luaD_rawrunprotected(L, direct_handler, NULL);
  L->ci = ci; L->allowhook = allowhook; L->errfunc = errfunc;
  if (status != LUA_OK) L->top.p = restorestack(L, top);
  return status;
}
static void *limited_allocator(void *data, void *ptr, size_t old, size_t size) {
  Allocation *a = data;
  if (a->armed && size > 0) ++a->watched_allocations;
  if (a->armed && a->mode == 0 && ptr == NULL && old == LUA_TUSERDATA &&
      size == sizeudata(0, sizeof(void *) + sizeof(size_t))) {
    ++a->hits;
    return NULL;
  }
  if (a->armed && a->mode == 1 && ptr == NULL && old == 0 &&
      size == (size_t)LUAL_BUFFERSIZE + ((size_t)LUAL_BUFFERSIZE >> 1)) {
    a->armed = 0;
    ++a->hits;
    a->nested_status = protected_handler(a->nested);
  }
  return a->original(a->data, ptr, old, size);
}
void trace_fixture_handler(lua_State *L) {
  int top = lua_gettop(L);
  lua_pushliteral(L, "trace-original");
  errorhandler(L);
  if (lua_type(L, -1) != LUA_TSTRING || strcmp(lua_tostring(L, -1), "trace-original"))
    luaL_error(L, "capture replaced original payload");
  lua_settop(L, top);
}
static void long_capture(lua_State *L, void *data) {
  (void)data;
  lua_pushvalue(L, 1);
  lua_pushinteger(L, LUAL_BUFFERSIZE / 32 + 40);
  lua_call(L, 1, 0);
}
static int prepare_capture(lua_State *L) {
  static const char source[] =
    "local leaf, outer = ...\n"
    "local function descend(n)\n"
    "  if n == 0 then leaf(); return end\n"
    "  descend(n-1)\n"
    "  return n\n"
    "end\n"
    "return function(n) outer(descend, n) end\n";
  lua_settop(L, 0);
  luaL_loadbuffer(L, source, sizeof source - 1,
    "@trace-buffer-long-declaring-source-for-real-merge-allocation.lua");
  lua_getglobal(L, "require"); lua_pushliteral(L, "trace_cases"); lua_call(L, 1, 1);
  lua_getfield(L, -1, "buffer_capture");
  lua_getfield(L, -2, "buffer_outer");
  lua_remove(L, -3);
  lua_call(L, 2, 1);
  if (!lua_checkstack(L, 2048)) return luaL_error(L, "cannot reserve trace allocation stack");
  /* Intern payload, keys, names and UBox metatable; retain the loaded closure
   * and a completed long trace while stopping GC to avoid unrelated finalizers. */
  long_capture(L, NULL);
  trace_fixture_backtrace(L);
  if (lua_rawlen(L, -1) <= (size_t)LUAL_BUFFERSIZE) return luaL_error(L, "calibration did not spill trace buffer");
  lua_pop(L, 1);
  lua_gc(L, LUA_GCSTOP);
  return 1;
}
int trace_fixture_allocation(lua_State *parent, int nested) {
  lua_State *state, *other;
  Allocation a = {0};
  int status, valid, top = lua_gettop(parent);
  if (!lua_checkstack(parent, 8)) return luaL_error(parent, "cannot reserve allocation fixture parent stack");
  state = new_state(parent); other = new_state(parent);
  lua_pushcfunction(state, prepare_capture);
  status = lua_pcall(state, 0, 1, 0);
  if (status != LUA_OK) {
    const char *why = lua_tostring(state, -1);
    fprintf(stderr, "trace allocation preparation: %s\n", why ? why : "unknown");
    lua_close(state); lua_close(other); return -1;
  }
  lua_pushliteral(other, "trace-original");
  errorhandler(other);
  lua_settop(other, 0);
  lua_pushliteral(other, "trace-original");
  lua_checkstack(other, 64);
  a.original = lua_getallocf(state, &a.data);
  a.nested = other; a.mode = nested; a.armed = 1; a.nested_status = -1;
  lua_setallocf(state, limited_allocator, &a);
  {
    CallInfo *ci = state->ci;
    lu_byte allowhook = state->allowhook;
    ptrdiff_t errfunc = state->errfunc;
    status = luaD_rawrunprotected(state, long_capture, NULL);
    a.armed = 0;
    lua_setallocf(state, a.original, a.data);
    state->ci = ci; state->allowhook = allowhook; state->errfunc = errfunc;
  }
  valid = a.hits > 0;
  if (nested) {
    valid = valid && lua_type(other, -1) == LUA_TSTRING &&
      strcmp(lua_tostring(other, -1), "trace-original") == 0;
    trace_fixture_backtrace(other);
    const char *trace = lua_tostring(other, -1);
    valid = valid && status == LUA_OK && a.hits == 1 && a.nested_status == LUA_OK && trace &&
      trace_fixture_count(trace, "(native Titan frames unavailable: capture failed)") == 1;
    if (trace) trace_fixture_emit("nested_held", trace);
    trace_fixture_backtrace(state);
    const char *outer = lua_tostring(state, -1);
    valid = valid && outer && strlen(outer) > (size_t)LUAL_BUFFERSIZE &&
      trace_fixture_count_frame_lines(outer, ": in trace_cases.buffer_capture") == 1 &&
      trace_fixture_count_frame_lines(outer, ": in trace_cases.buffer_outer") == 1 &&
      parent_runner_frame(outer, 113, ": in titan_test_runner_ℳ_run_test_28_titan") &&
      parent_runner_frame(outer, 239, ": in titan_test_runner_ℳ_main_titan") &&
      !strstr(outer, "(native Titan frames unavailable:");
    if (outer) trace_fixture_emit("nested_outer", outer);
    lua_pop(state, 1);
  } else valid = valid && status == LUA_ERRMEM;
  printf("TRACE-ALLOCATION mode=%s status=%d hits=%d watched=%zu buffer=%d\n",
    nested ? "nested" : "limit", status, a.hits, a.watched_allocations, LUAL_BUFFERSIZE);
  fflush(stdout);
  lua_settop(state, 1);
  /* This handler uses the same static storage after both protected outcomes. */
  valid = valid && scenario(state,
    "local m,s=require('trace_cases'),require('titan'); s.clear(); local ok,e=pcall(m.reraiser,'after-allocation'); assert(not ok and e=='after-allocation'); assert(s.backtrace():find('in trace_cases.reraiser',1,true))") == LUA_OK;
  lua_close(state); lua_close(other);
  lua_settop(parent, top);
  return valid ? status : -1;
}
