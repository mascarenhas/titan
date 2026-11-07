#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <lauxlib.h>
#include <titan.h>
#include <titan/browser.h>

typedef void (*titan_browser_invoke_fn)(lua_State *L, Udata *module,
    CClosure *closure, uint64_t id, uint32_t state, uint32_t slot,
    uint32_t generation, uint32_t argc, const titan_browser_value *args);
typedef void (*titan_browser_release_fn)(lua_State *L, Udata *module,
    CClosure *closure, uint64_t id, uint32_t state, uint32_t slot,
    uint32_t generation);
typedef void (*titan_browser_pin_fn)(lua_State *L, Udata *module,
    CClosure *closure, TValue callable, titan_browser_identity *out);
typedef void (*titan_browser_unpin_fn)(lua_State *L, Udata *module,
    CClosure *closure, uint32_t state, uint32_t slot, uint32_t generation);

/* Registered before libraries or Titan modules can create a finalizable
 * object. Lua closes in reverse registration order, so it retires the state
 * only after every user and coroutine finalizer has finished. */
typedef struct bridge_state {
  lua_State *L;
  struct bridge_state *next;
  uint32_t token;
  int closing;
  Udata *module;
  CClosure *invoke_closure;
  titan_browser_invoke_fn invoke;
  CClosure *release_closure;
  titan_browser_release_fn release;
  CClosure *pin_closure;
  titan_browser_pin_fn pin;
  CClosure *unpin_closure;
  titan_browser_unpin_fn unpin;
} bridge_state;

static char registry_key, saved_trace_key;
static bridge_state *states;
static lua_State *owner;
static int initialized, owner_ready, main_started;
static int converting_error, saved_trace_set;
static const char *image_name;

static bridge_state *find_state(uint32_t token) {
  bridge_state *state;
  for (state = states; state; state = state->next) {
    if (state->token == token) return state;
  }
  return NULL;
}

static bridge_state *find_lua_state(lua_State *L) {
  lua_State *main_L = mainthread(G(L));
  bridge_state *state;
  for (state = states; state; state = state->next) {
    if (state->L == main_L) return state;
  }
  return NULL;
}

static void mark_closing(bridge_state *state) {
  if (!state->closing) {
    state->closing = 1;
    state->module = NULL;
    state->invoke_closure = NULL;
    state->invoke = NULL;
    state->release_closure = NULL;
    state->release = NULL;
    state->pin_closure = NULL;
    state->pin = NULL;
    state->unpin_closure = NULL;
    state->unpin = NULL;
    titan_browser_host_state_closing(state->token);
  }
}

/* Rule 1 exception: earliest-registered __gc finalizer runs after all module
 * and coroutine finalizers during lua_close to invalidate host state slots. */
static int state_gc(lua_State *L) {
  bridge_state *state = (bridge_state *)lua_touserdata(L, 1);
  bridge_state **cursor;
  if (!state->token) return 0;
  mark_closing(state);
  titan_browser_host_state_closed(state->token);
  for (cursor = &states; *cursor != state; cursor = &(*cursor)->next) {}
  *cursor = state->next;
  state->token = 0;
  return 0;
}

/* Rule 1 exception: runs before luaL_openlibs and before any Titan module
 * exists so the state-invalidation userdata is finalized last on lua_close. */
uint32_t titan_browser_attach(lua_State *L) {
  bridge_state *state = find_lua_state(L);
  if (state) return state->token;
  luaL_checkstack(L, 3, "browser state registry");
  state = (bridge_state *)lua_newuserdatauv(L, sizeof(*state), 0);
  memset(state, 0, sizeof(*state));
  state->L = mainthread(G(L));
  lua_newtable(L);
  lua_pushcfunction(L, state_gc);
  lua_setfield(L, -2, "__gc");
  lua_setmetatable(L, -2);
  lua_rawsetp(L, LUA_REGISTRYINDEX, &registry_key);
  /* No allocating Lua operation follows token publication. A partial attach
   * can therefore never leave a host state with no invalidation owner. */
  state->token = titan_browser_host_state_open();
  if (!state->token) luaL_error(L, "browser state identity exhausted");
  state->next = states;
  states = state;
  return state->token;
}

/* Rule 2: pure C lookup over the state-token list; detects GCSTPCLS for direct
 * lua_close on an independent state before its first close-phase import. */
uint32_t titan_browser_state(lua_State *L) {
  bridge_state *state = find_lua_state(L);
  if (!state || !state->token) return 0;
  if (G(L)->gcstp & GCSTPCLS) mark_closing(state);
  return state->token;
}

/* Rule 2: pure C close-admission check over the state-token list. */
int titan_browser_state_closing(lua_State *L) {
  bridge_state *state = find_lua_state(L);
  if (!state || !state->token) return 1;
  if (G(L)->gcstp & GCSTPCLS) mark_closing(state);
  return state->closing;
}

/* Rule 1 exception: owner-held lua_close, never a pcall on the freeing state. */
void titan_browser_close_state(lua_State *L) {
  bridge_state *state = find_lua_state(L);
  if (state) mark_closing(state);
  lua_close(L);
}

/* Rule 1 exception: records Titan entry closures rooted in browser module
 * variables so C shims can dispatch directly to Titan native entries. */
void titan_browser_configure(lua_State *L, Udata *module,
    TValue invoke_handler, TValue release_handler,
    TValue pin_handler, TValue unpin_handler) {
  bridge_state *state = find_lua_state(L);
  if (!state || state->closing) return;
  state->module = module;
  state->invoke_closure = clCvalue(&invoke_handler);
  state->invoke = titan_cast_func(titan_browser_invoke_fn,
      pvalue(&state->invoke_closure->upvalue[2]));
  state->release_closure = clCvalue(&release_handler);
  state->release = titan_cast_func(titan_browser_release_fn,
      pvalue(&state->release_closure->upvalue[2]));
  state->pin_closure = clCvalue(&pin_handler);
  state->pin = titan_cast_func(titan_browser_pin_fn,
      pvalue(&state->pin_closure->upvalue[2]));
  state->unpin_closure = clCvalue(&unpin_handler);
  state->unpin = titan_cast_func(titan_browser_unpin_fn,
      pvalue(&state->unpin_closure->upvalue[2]));
}

/* Rule 1 & M10 exception: C SDK shim delegating callable pinning to Titan. */
void titan_browser_pin_callable(lua_State *L, TValue callable,
    titan_browser_identity *out) {
  bridge_state *state = find_lua_state(L);
  int top;
  if (state && (G(L)->gcstp & GCSTPCLS)) mark_closing(state);
  if (!state || state->closing || !state->pin)
    luaL_error(L, "browser state is closing or uninitialized");
  if (!lua_checkstack(L, LUA_MINSTACK))
    luaL_error(L, "not enough memory for browser callable pin");
  top = lua_gettop(L);
  state->pin(L, state->module, state->pin_closure, callable, out);
  lua_settop(L, top);
}

/* Rule 1 & M10 exception: C SDK shim delegating callable unpinning to Titan. */
void titan_browser_unpin_callable(lua_State *L,
    const titan_browser_identity *identity) {
  bridge_state *state;
  int top;
  if (!identity->slot) return;
  state = find_lua_state(L);
  if (!state || state->token != identity->state)
    luaL_error(L, "browser callable belongs to another state");
  if (!state->unpin) return;
  if (!lua_checkstack(L, LUA_MINSTACK))
    luaL_error(L, "not enough memory for browser callable release");
  top = lua_gettop(L);
  state->unpin(L, state->module, state->unpin_closure,
      identity->state, identity->slot, identity->generation);
  lua_settop(L, top);
}

/* Rule 2: plain C cleanup of malloc-owned response buffers and unadopted slots. */
void titan_browser_response_dispose(titan_browser_response *response) {
  if (response->value.kind == TITAN_BROWSER_STRING ||
      response->value.kind == TITAN_BROWSER_BYTES)
    free((void *)response->value.bytes);
  if ((response->value.kind == TITAN_BROWSER_HANDLE ||
       response->value.kind == TITAN_BROWSER_REQUEST) && response->value.slot)
    titan_browser_host_release(response->state, response->value.slot, response->value.generation);
  if (response->thrown_slot)
    titan_browser_host_release(response->state, response->thrown_slot, response->thrown_generation);
  free((void *)response->message);
  memset(response, 0, sizeof(*response));
}

/* Rule 1 exception: exact exported C allocation names required by the loader. */
void *titan_browser_alloc(size_t length) { return malloc(length ? length : 1); }
void titan_browser_free(void *buffer) { free(buffer); }

static void flush_completion(titan_browser_completion *completion) {
  int out = fflush(stdout), err = fflush(stderr);
  if (completion->status == TITAN_BROWSER_OK && (out || err)) {
    static const unsigned char out_error[] = "cannot flush browser stdout";
    static const unsigned char err_error[] = "cannot flush browser stderr";
    completion->status = TITAN_BROWSER_TITAN_ERROR;
    completion->application_status = 1;
    completion->message = out ? out_error : err_error;
    completion->message_length = (uint32_t)(out ? sizeof(out_error) - 1 : sizeof(err_error) - 1);
  }
  titan_browser_complete(completion);
}

static int invalid_entry(uint64_t id, uint32_t operation, const char *message) {
  titan_browser_completion completion = {0};
  completion.operation_id = id;
  completion.operation = operation;
  completion.status = TITAN_BROWSER_STATE;
  completion.application_status = 1;
  completion.message = (const unsigned char *)message;
  completion.message_length = (uint32_t)strlen(message);
  flush_completion(&completion);
  return 0;
}

/* Rule 1 & M7 exception: message handler for the image bootstrap/main pcall.
 * Captures the unified trace, then converts non-string error objects while
 * preserving the original trace snapshot across throwing __tostring hooks. */
static int entry_errorhandler(lua_State *L) {
  errorhandler(L);
  if (lua_isstring(L, 1)) {
    lua_tolstring(L, 1, NULL);
    return 1;
  }
  lua_getfield(L, LUA_REGISTRYINDEX, TITAN_BACKTRACE_KEY);
  lua_rawsetp(L, LUA_REGISTRYINDEX, &saved_trace_key);
  saved_trace_set = 1;
  L->errfunc = 0;
  converting_error = 1;
  if (!luaL_callmeta(L, 1, "__tostring") || lua_type(L, -1) != LUA_TSTRING)
    lua_pushfstring(L, "(error object is a %s value)", luaL_typename(L, 1));
  converting_error = 0;
  return 1;
}

static void complete_failure(lua_State *L, titan_browser_completion *completion) {
  static const unsigned char conversion_error[] =
      "error while reporting browser failure";
  static const char prefix[] = "[string \"local arg = ...;...\"]:3: ";
  size_t length = 0, trace_length = 0;
  const unsigned char *message;
  const char *trace;
  completion->status = TITAN_BROWSER_TITAN_ERROR;
  completion->application_status = 1;
  if (saved_trace_set) {
    titan_unwind_clear_trace(L);
    lua_rawgetp(L, LUA_REGISTRYINDEX, &saved_trace_key);
    lua_setfield(L, LUA_REGISTRYINDEX, TITAN_BACKTRACE_KEY);
    lua_pushnil(L);
    lua_rawsetp(L, LUA_REGISTRYINDEX, &saved_trace_key);
    saved_trace_set = 0;
  }
  if (converting_error) {
    converting_error = 0;
    message = conversion_error;
    length = sizeof(conversion_error) - 1;
  } else {
    const char *raw = lua_tolstring(L, -1, &length);
    if (!raw) {
      message = conversion_error;
      length = sizeof(conversion_error) - 1;
    } else {
      while (length >= sizeof(prefix) - 1 &&
             !memcmp(raw, prefix, sizeof(prefix) - 1)) {
        raw += sizeof(prefix) - 1;
        length -= sizeof(prefix) - 1;
      }
      message = (const unsigned char *)raw;
    }
  }
  completion->message = message;
  completion->message_length = (uint32_t)length;
  lua_getfield(L, LUA_REGISTRYINDEX, TITAN_BACKTRACE_KEY);
  trace = lua_tolstring(L, -1, &trace_length);
  completion->trace = (const unsigned char *)trace;
  completion->trace_length = trace ? (uint32_t)trace_length : 0;
  if (message == conversion_error) {
    fwrite(message, 1, length, stderr);
    fputc('\n', stderr);
  } else {
    fputs(image_name ? image_name : "titan", stderr);
    fputs(": ", stderr);
    fwrite(message, 1, length, stderr);
    fputc('\n', stderr);
    if (trace) {
      const char *cursor = trace, *limit = trace + trace_length;
      fputs("stack traceback:", stderr);
      while (cursor < limit) {
        const char *end = memchr(cursor, '\n', (size_t)(limit - cursor));
        size_t count = end ? (size_t)(end - cursor) : (size_t)(limit - cursor);
        fputs("\n\t", stderr);
        fwrite(cursor, 1, count, stderr);
        if (!end) break;
        cursor = end + 1;
      }
      fputc('\n', stderr);
    }
  }
  flush_completion(completion);
}

/* Rule 1 & M7 exception: shared protected launcher boundary for initialize and
 * main in images that may not link or have not yet initialized titan.browser. */
static int protected_entry(uint64_t id, uint32_t operation, lua_State *L,
    lua_CFunction worker, void *context, int main_result) {
  int top = lua_gettop(L);
  titan_browser_completion completion = {0};
  completion.operation_id = id;
  completion.operation = operation;
  if (!lua_checkstack(L, 6))
    return invalid_entry(id, operation, "not enough memory for browser entry stack");
  lua_pushcfunction(L, entry_errorhandler);
  lua_pushcfunction(L, worker);
  lua_pushlightuserdata(L, context);
  if (lua_pcall(L, 1, main_result, top + 1) != LUA_OK) {
    complete_failure(L, &completion);
  } else {
    if (main_result) {
      uint32_t low = (uint32_t)(lua_Unsigned)lua_tointeger(L, -1);
      completion.application_status = low <= INT32_MAX ? (int32_t)low : -1 - (int32_t)(UINT32_MAX - low);
    }
    flush_completion(&completion);
  }
  lua_settop(L, top);
  return 0;
}

typedef struct initialize_context { lua_CFunction function; } initialize_context;
static int initialize_worker(lua_State *L) {
  initialize_context *context = (initialize_context *)lua_touserdata(L, 1);
  titan_browser_attach(L);
  lua_settop(L, 0);
  context->function(L);
  owner_ready = 1;
  return 0;
}

/* Rule 1 exception: exported initialize collaborator before modules exist. */
int titan_browser_initialize_image(uint64_t id, lua_CFunction initialize,
    const char *program_name, int state_status) {
  initialize_context context = {initialize};
  if (!id || !titan_browser_entry_allowed(id, TITAN_BROWSER_INITIALIZE)) return -1;
  if (initialized) return invalid_entry(id, TITAN_BROWSER_INITIALIZE, "browser instance is already initialized");
  initialized = 1;
  image_name = program_name;
  owner = luaL_newstate();
  if (!owner) {
    titan_browser_completion completion = {0};
    static const unsigned char message[] = "not enough memory for state";
    completion.operation_id = id;
    completion.operation = TITAN_BROWSER_INITIALIZE;
    completion.status = TITAN_BROWSER_MEMORY;
    completion.application_status = state_status;
    completion.message = message;
    completion.message_length = sizeof(message) - 1;
    flush_completion(&completion);
    return 0;
  }
  return protected_entry(id, TITAN_BROWSER_INITIALIZE, owner, initialize_worker, &context, 0);
}

/* Rule 1 & M7 exception: exported main collaborator for program/probe images. */
int titan_browser_main_image(uint64_t id, lua_CFunction main, void *arguments) {
  if (!id || !titan_browser_entry_allowed(id, TITAN_BROWSER_MAIN)) return -1;
  if (!owner || !owner_ready || main_started)
    return invalid_entry(id, TITAN_BROWSER_MAIN, "browser main is unavailable or already invoked");
  main_started = 1;
  return protected_entry(id, TITAN_BROWSER_MAIN, owner, main, arguments, 1);
}

/* Rule 1 exception: exported close collaborator. */
int titan_browser_close_image(uint64_t id) {
  titan_browser_completion completion = {0};
  if (!id || !titan_browser_entry_allowed(id, TITAN_BROWSER_CLOSE)) return -1;
  completion.operation_id = id;
  completion.operation = TITAN_BROWSER_CLOSE;
  if (owner) {
    lua_State *L = owner;
    owner = NULL;
    titan_browser_close_state(L);
  }
  flush_completion(&completion);
  return 0;
}

/* Rule 1 & 3 exception: exported Emscripten invoke gateway; recovers state and
 * dispatches directly to the Titan invoke_entry with no lua_pcall. */
int titan_browser_invoke(uint64_t id, uint32_t token, uint32_t slot,
    uint32_t generation, uint32_t argc, const titan_browser_value *args) {
  bridge_state *state;
  ptrdiff_t old_errfunc;
  int top;
  if (!id || !titan_browser_entry_allowed(id, TITAN_BROWSER_INVOKE)) return -1;
  state = find_state(token);
  if (!state || state->closing || !state->invoke || (state->L == owner && !owner_ready))
    return invalid_entry(id, TITAN_BROWSER_INVOKE, "browser state is closed, closing or uninitialized");
  if (!lua_checkstack(state->L, LUA_MINSTACK))
    return invalid_entry(id, TITAN_BROWSER_INVOKE, "not enough memory for browser entry stack");
  old_errfunc = state->L->errfunc;
  top = lua_gettop(state->L);
  lua_pushcfunction(state->L, errorhandler);
  state->L->errfunc = savestack(state->L, state->L->top.p - 1);
  state->invoke(state->L, state->module, state->invoke_closure,
      id, token, slot, generation, argc, args);
  state->L->errfunc = old_errfunc;
  lua_settop(state->L, top);
  return 0;
}

/* Rule 1 & 3 exception: exported Emscripten release gateway; recovers state and
 * dispatches directly to the Titan release_entry with no lua_pcall. */
int titan_browser_release_callable(uint64_t id, uint32_t token,
    uint32_t slot, uint32_t generation) {
  bridge_state *state;
  ptrdiff_t old_errfunc;
  int top;
  if (!id || !titan_browser_entry_allowed(id, TITAN_BROWSER_RELEASE)) return -1;
  state = find_state(token);
  if (!state || !state->release)
    return invalid_entry(id, TITAN_BROWSER_RELEASE, "browser state is closed");
  if (!lua_checkstack(state->L, LUA_MINSTACK))
    return invalid_entry(id, TITAN_BROWSER_RELEASE, "not enough memory for browser entry stack");
  old_errfunc = state->L->errfunc;
  top = lua_gettop(state->L);
  lua_pushcfunction(state->L, errorhandler);
  state->L->errfunc = savestack(state->L, state->L->top.p - 1);
  state->release(state->L, state->module, state->release_closure,
      id, token, slot, generation);
  state->L->errfunc = old_errfunc;
  lua_settop(state->L, top);
  return 0;
}
