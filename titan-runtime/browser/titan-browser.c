#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <lauxlib.h>
#include <titan.h>
#include <titan/browser.h>

/* This object is registered before libraries or Titan modules can create a
 * finalizable object. Lua closes in reverse registration order, so it retires
 * the state only after every user/coroutine finalizer has finished. */
typedef struct bridge_state {
  lua_State *L;
  struct bridge_state *next;
  uint32_t token;
  int closing;
} bridge_state;
typedef struct bridge_callable {
  uint32_t generation;
  titan_browser_signature signature;
  uint32_t kinds[];
} bridge_callable;
static char registry_key;
static bridge_state *states;
static lua_State *owner;
static int initialized, owner_ready, main_started;
static const char *image_name;

static void mark_closing(bridge_state *state) {
  if (!state->closing) {
    state->closing = 1;
    titan_browser_host_state_closing(state->token);
  }
}

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

static bridge_state *push_state(lua_State *L) {
  bridge_state *state;
  lua_rawgetp(L, LUA_REGISTRYINDEX, &registry_key);
  state = (bridge_state *)lua_touserdata(L, -1);
  if (!state || !state->token) luaL_error(L, "browser state is not attached");
  /* Also covers an independently owned state's direct lua_close/GC path:
   * GCSTPCLS is already set before the first close-phase finalizer runs. */
  if (G(L)->gcstp & GCSTPCLS) mark_closing(state);
  return state;
}

uint32_t titan_browser_attach(lua_State *L) {
  bridge_state *state;
  int top = lua_gettop(L);
  luaL_checkstack(L, 6, "browser state registry");
  lua_rawgetp(L, LUA_REGISTRYINDEX, &registry_key);
  if (!lua_isnil(L, -1)) {
    state = (bridge_state *)lua_touserdata(L, -1);
    lua_settop(L, top);
    return state->token;
  }
  lua_pop(L, 1);
  state = (bridge_state *)lua_newuserdatauv(L, sizeof(*state), 3);
  memset(state, 0, sizeof(*state));
  state->L = mainthread(G(L));
  lua_newtable(L);
  lua_pushcfunction(L, state_gc);
  lua_setfield(L, -2, "__gc");
  lua_setmetatable(L, -2);
  lua_newtable(L); lua_setiuservalue(L, -2, 1); /* original closures/signatures */
  lua_newtable(L); lua_setiuservalue(L, -2, 2); /* generations survive release */
  lua_createtable(L, 4, 0); lua_setiuservalue(L, -2, 3); /* nominal adapters */
  lua_pushvalue(L, -1);
  lua_rawsetp(L, LUA_REGISTRYINDEX, &registry_key);
  /* No allocating Lua operation follows token publication. A partial attach
   * can therefore never leave a host state with no invalidation owner. */
  state->token = titan_browser_host_state_open();
  if (!state->token) luaL_error(L, "browser state identity exhausted");
  state->next = states;
  states = state;
  lua_settop(L, top);
  return state->token;
}

uint32_t titan_browser_state(lua_State *L) {
  bridge_state *state;
  uint32_t token;
  luaL_checkstack(L, 1, "browser state identity");
  state = push_state(L);
  token = state->token;
  lua_pop(L, 1);
  return token;
}

int titan_browser_state_closing(lua_State *L) {
  bridge_state *state;
  int closing;
  luaL_checkstack(L, 1, "browser close admission");
  state = push_state(L);
  closing = state->closing;
  lua_pop(L, 1);
  return closing;
}

void titan_browser_close_state(lua_State *L) {
  bridge_state *state;
  /* Looking up the C-owned list neither allocates nor runs Lua on close. */
  for (state = states; state; state = state->next) {
    if (state->L == mainthread(G(L))) { mark_closing(state); break; }
  }
  lua_close(L); /* Never pcall on the state being freed. */
}

void titan_browser_configure(lua_State *L, TValue handle_factory,
    TValue callable_factory, TValue handle_identity, TValue callable_identity) {
  int top = lua_gettop(L);
  luaL_checkstack(L, 3, "browser nominal adapters");
  push_state(L);
  lua_getiuservalue(L, -1, 3);
  lua_pushtvalue(L, handle_factory); lua_rawseti(L, -2, 1);
  lua_pushtvalue(L, callable_factory); lua_rawseti(L, -2, 2);
  lua_pushtvalue(L, handle_identity); lua_rawseti(L, -2, 3);
  lua_pushtvalue(L, callable_identity); lua_rawseti(L, -2, 4);
  lua_settop(L, top);
}

static void push_adapter(lua_State *L, int which) {
  push_state(L);
  lua_getiuservalue(L, -1, 3);
  lua_rawgeti(L, -1, which);
  lua_remove(L, -2);
  lua_remove(L, -2);
  if (!lua_isfunction(L, -1)) luaL_error(L, "browser module is not initialized in this state");
}

typedef struct callable_root_context {
  int slot;
  uint32_t generation;
} callable_root_context;

/* The caller owns rollback until every raising bookkeeping step succeeds.
 * Tables and userdata are real Lua arguments, never movable stack pointers. */
static int root_callable_worker(lua_State *L) {
  callable_root_context *context = (callable_root_context *)lua_touserdata(L, 1);
  uint32_t generation;
  lua_pushvalue(L, 4);
  context->slot = luaL_ref(L, 2);
  lua_rawgeti(L, 3, context->slot);
  generation = lua_isnil(L, -1) ? 1 : (uint32_t)lua_tointeger(L, -1) + 1;
  lua_pop(L, 1);
  if (!generation) luaL_error(L, "browser callable generation exhausted");
  lua_pushinteger(L, generation);
  lua_rawseti(L, 3, context->slot);
  context->generation = generation;
  return 0;
}

void titan_browser_root_callable(lua_State *L, TValue original,
    const titan_browser_signature *signature, titan_browser_identity *out) {
  bridge_state *state;
  bridge_callable *callable;
  CClosure *closure;
  uint32_t i;
  uint64_t count = (uint64_t)signature->parameter_count + signature->result_count;
  int top = lua_gettop(L), registry, roots, generations, value;
  callable_root_context context = {0, 0};
  if (!ttisCclosure(&original)) luaL_error(L, "browser callable requires a Titan function");
  closure = clCvalue(&original);
  if (closure->nupvalues < 5 || !ttislightuserdata(&closure->upvalue[3]) ||
      pvalue(&closure->upvalue[3]) != TITAN_BRAND)
    luaL_error(L, "browser callable requires a Titan function");
  if (count > (SIZE_MAX - sizeof(*callable)) / sizeof(uint32_t) ||
      signature->parameter_count > INT_MAX - 8 || signature->result_count > INT_MAX - 8 ||
      signature->result_count > SIZE_MAX / sizeof(titan_browser_value))
    luaL_error(L, "browser callable signature is too large");
  luaL_checkstack(L, 12, "browser callable root transaction");
  state = push_state(L);
  if (state->closing) luaL_error(L, "browser state is closing");
  registry = lua_gettop(L);
  lua_getiuservalue(L, registry, 1); roots = lua_gettop(L);
  lua_getiuservalue(L, registry, 2); generations = lua_gettop(L);
  callable = (bridge_callable *)lua_newuserdatauv(L,
      sizeof(*callable) + count * sizeof(uint32_t), 1);
  callable->signature.parameter_count = signature->parameter_count;
  callable->signature.result_count = signature->result_count;
  callable->signature.parameters = callable->kinds;
  callable->signature.results = callable->kinds + signature->parameter_count;
  for (i = 0; i < signature->parameter_count; ++i) callable->kinds[i] = signature->parameters[i];
  for (i = 0; i < signature->result_count; ++i)
    callable->kinds[signature->parameter_count + i] = signature->results[i];
  lua_pushtvalue(L, original);
  lua_setiuservalue(L, -2, 1);
  value = lua_gettop(L);
  lua_pushcfunction(L, root_callable_worker);
  lua_pushlightuserdata(L, &context);
  lua_pushvalue(L, roots);
  lua_pushvalue(L, generations);
  lua_pushvalue(L, value);
  if (lua_pcall(L, 4, 0, 0) != LUA_OK) {
    /* A successful luaL_ref has already created both existing unref keys.
     * Rollback only overwrites them, even while allocation remains failed. */
    if (context.slot > 0) luaL_unref(L, roots, context.slot);
    lua_error(L);
  }
  callable->generation = context.generation;
  out->state = state->token;
  out->slot = (uint32_t)context.slot;
  out->generation = context.generation;
  titan_browser_host_callable(out->state, out->slot, context.generation, &callable->signature);
  lua_settop(L, top);
}

static bridge_callable *push_callable(lua_State *L, uint32_t slot, uint32_t generation) {
  bridge_callable *callable;
  push_state(L);
  lua_getiuservalue(L, -1, 1);
  lua_rawgeti(L, -1, slot);
  lua_remove(L, -2); lua_remove(L, -2);
  callable = (bridge_callable *)lua_touserdata(L, -1);
  if (!callable || callable->generation != generation)
    luaL_error(L, "browser callable is released");
  return callable;
}

void titan_browser_drop_callable(lua_State *L, const titan_browser_identity *identity) {
  bridge_state *state;
  bridge_callable *callable;
  int top = lua_gettop(L), roots;
  if (!identity->slot) return;
  luaL_checkstack(L, 3, "browser callable release");
  state = push_state(L);
  if (state->token != identity->state) luaL_error(L, "browser callable belongs to another state");
  lua_getiuservalue(L, -1, 1); roots = lua_gettop(L);
  lua_rawgeti(L, roots, identity->slot);
  callable = (bridge_callable *)lua_touserdata(L, -1);
  if (callable && callable->generation == identity->generation) {
    luaL_unref(L, roots, (int)identity->slot);
    titan_browser_host_callable_closed(identity->state, identity->slot, identity->generation);
  }
  lua_settop(L, top);
}

void titan_browser_response_dispose(titan_browser_response *response) {
  if (response->value.kind == TITAN_BROWSER_BYTES) free((void *)response->value.bytes);
  if ((response->value.kind == TITAN_BROWSER_HANDLE ||
       response->value.kind == TITAN_BROWSER_REQUEST) && response->value.slot)
    titan_browser_host_release(response->state, response->value.slot, response->value.generation);
  if (response->thrown_slot)
    titan_browser_host_release(response->state, response->thrown_slot, response->thrown_generation);
  free((void *)response->message);
  memset(response, 0, sizeof(*response));
}
void *titan_browser_alloc(size_t length) { return malloc(length ? length : 1); }
void titan_browser_free(void *buffer) { free(buffer); }

/* Error conversion runs under a second pcall WITHOUT errorhandler, preserving
 * the already captured raw trace even if __tostring itself raises. */
static int error_description(lua_State *L) {
  size_t length, trace_length;
  const char *message = lua_tolstring(L, 1, &length), *trace;
  int report = lua_toboolean(L, 2);
  static const char prefix[] = "[string \"local arg = ...;...\"]:3: ";
  if (!message) {
    if (!luaL_callmeta(L, 1, "__tostring") || lua_type(L, -1) != LUA_TSTRING)
      lua_pushfstring(L, "(error object is a %s value)", luaL_typename(L, 1));
    message = lua_tolstring(L, -1, &length);
  }
  while (length >= sizeof(prefix) - 1 && !memcmp(message, prefix, sizeof(prefix) - 1)) {
    message += sizeof(prefix) - 1;
    length -= sizeof(prefix) - 1;
  }
  lua_pushlstring(L, message, length);
  lua_pushvalue(L, 3); /* snapshot captured before any __tostring execution */
  trace = lua_tolstring(L, -1, &trace_length);
  if (report) {
    fputs(image_name ? image_name : "titan", stderr); fputs(": ", stderr);
    /* Reacquire the rooted message after pushing the original trace. */
    message = lua_tolstring(L, -2, &length);
    fwrite(message, 1, length, stderr); fputc('\n', stderr);
    if (trace) {
      const char *cursor = trace, *limit = trace + trace_length;
      fputs("stack traceback:", stderr);
      while (cursor < limit) {
        const char *end = memchr(cursor, '\n', (size_t)(limit - cursor));
        size_t count = end ? (size_t)(end - cursor) : (size_t)(limit - cursor);
        fputs("\n\t", stderr); fwrite(cursor, 1, count, stderr);
        if (!end) break;
        cursor = end + 1;
      }
      fputc('\n', stderr);
    }
  }
  return 2;
}

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
static int original_trace(lua_State *L) {
  lua_getfield(L, LUA_REGISTRYINDEX, TITAN_BACKTRACE_KEY);
  return 1;
}
static int restore_trace(lua_State *L) {
  titan_unwind_clear_trace(L); /* also consume a converter's pending re-raise pin */
  lua_pushvalue(L, 1);
  lua_setfield(L, LUA_REGISTRYINDEX, TITAN_BACKTRACE_KEY);
  return 0;
}

static void complete_failure(lua_State *L, titan_browser_completion *completion, int report) {
  static const unsigned char conversion_error[] = "error while reporting browser failure";
  size_t length;
  int error_index = lua_gettop(L), trace_index;
  completion->status = TITAN_BROWSER_TITAN_ERROR;
  completion->application_status = 1;
  lua_pushcfunction(L, original_trace);
  if (lua_pcall(L, 0, 1, 0) != LUA_OK) { lua_pop(L, 1); lua_pushnil(L); }
  trace_index = lua_gettop(L);
  lua_pushcfunction(L, error_description);
  lua_pushvalue(L, error_index);
  lua_pushboolean(L, report);
  lua_pushvalue(L, trace_index);
  if (lua_pcall(L, 3, 2, 0) != LUA_OK) {
    completion->message = conversion_error;
    completion->message_length = sizeof(conversion_error) - 1;
    if (report) { fwrite(conversion_error, 1, sizeof(conversion_error) - 1, stderr); fputc('\n', stderr); }
  } else {
    completion->message = (const unsigned char *)lua_tolstring(L, -2, &length);
    completion->message_length = (uint32_t)length;
  }
  completion->trace = lua_type(L, trace_index) == LUA_TSTRING
      ? (const unsigned char *)lua_tolstring(L, trace_index, &length) : NULL;
  completion->trace_length = completion->trace ? (uint32_t)length : 0;
  /* A converter may itself catch an unrelated Titan error, which updates the
   * registry even without our errorhandler. Restore the original snapshot. */
  lua_pushcfunction(L, restore_trace);
  lua_pushvalue(L, trace_index);
  if (lua_pcall(L, 1, 0, 0) != LUA_OK) lua_pop(L, 1);
  flush_completion(completion);
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

/* checkstack is nonraising. Only the three allocation-free initial pushes
 * occur outside protection; all Lua work and result encoding are in worker. */
static int protected_entry(uint64_t id, uint32_t operation, lua_State *L,
    lua_CFunction worker, void *context, int report, int main_result) {
  int top = lua_gettop(L);
  titan_browser_completion completion = {0};
  completion.operation_id = id;
  completion.operation = operation;
  if (!lua_checkstack(L, 8)) return invalid_entry(id, operation, "not enough memory for browser entry stack");
  lua_pushcfunction(L, errorhandler);
  lua_pushcfunction(L, worker);
  lua_pushlightuserdata(L, context);
  if (lua_pcall(L, 1, main_result == 1 ? 1 : 0, top + 1) != LUA_OK) {
    complete_failure(L, &completion, report);
  } else {
    if (main_result == 1) {
      uint32_t low = (uint32_t)(lua_Unsigned)lua_tointeger(L, -1);
      completion.application_status = low <= INT32_MAX ? (int32_t)low : -1 - (int32_t)(UINT32_MAX - low);
    }
    if (main_result >= 0) flush_completion(&completion);
  }
  lua_settop(L, top);
  return 0;
}

typedef struct initialize_context { lua_CFunction function; } initialize_context;
static int initialize_worker(lua_State *L) {
  initialize_context *context = (initialize_context *)lua_touserdata(L, 1);
  titan_browser_attach(L);
  lua_settop(L, 0);
  lua_pushcfunction(L, context->function);
  lua_call(L, 0, 0);
  owner_ready = 1;
  return 0;
}
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
    completion.message = message; completion.message_length = sizeof(message) - 1;
    flush_completion(&completion);
    return 0;
  }
  return protected_entry(id, TITAN_BROWSER_INITIALIZE, owner, initialize_worker, &context, 1, 0);
}
int titan_browser_main_image(uint64_t id, lua_CFunction main, void *arguments) {
  if (!id || !titan_browser_entry_allowed(id, TITAN_BROWSER_MAIN)) return -1;
  if (!owner || !owner_ready || main_started)
    return invalid_entry(id, TITAN_BROWSER_MAIN, "browser main is unavailable or already invoked");
  main_started = 1;
  return protected_entry(id, TITAN_BROWSER_MAIN, owner, main, arguments, 1, 1);
}
int titan_browser_close_image(uint64_t id) {
  titan_browser_completion completion = {0};
  if (!id || !titan_browser_entry_allowed(id, TITAN_BROWSER_CLOSE)) return -1;
  completion.operation_id = id; completion.operation = TITAN_BROWSER_CLOSE;
  if (owner) {
    lua_State *L = owner;
    owner = NULL;
    titan_browser_close_state(L);
  }
  flush_completion(&completion);
  return 0;
}

static bridge_state *find_state(uint32_t token) {
  bridge_state *state;
  for (state = states; state; state = state->next) if (state->token == token) return state;
  return NULL;
}

static void push_argument(lua_State *L, uint32_t state, uint32_t kind,
    const titan_browser_value *value) {
  if (value->kind != kind) luaL_error(L, "browser callback argument kind mismatch");
  switch (kind) {
    case TITAN_BROWSER_NIL: lua_pushnil(L); break;
    case TITAN_BROWSER_BOOLEAN:
      if (value->scalar.integer != 0 && value->scalar.integer != 1)
        luaL_error(L, "browser callback boolean must be true or false");
      lua_pushboolean(L, (int)value->scalar.integer); break;
    case TITAN_BROWSER_INTEGER: lua_pushinteger(L, value->scalar.integer); break;
    case TITAN_BROWSER_FLOAT: lua_pushnumber(L, value->scalar.number); break;
    case TITAN_BROWSER_BYTES:
      if (value->length && !value->bytes) luaL_error(L, "browser byte argument has no storage");
      lua_pushlstring(L, value->length ? (const char *)value->bytes : "", value->length); break;
    case TITAN_BROWSER_HANDLE:
    case TITAN_BROWSER_CALLABLE:
      if (value->state != state || !value->slot || !value->generation)
        luaL_error(L, "browser argument belongs to another or retired state");
      if (kind == TITAN_BROWSER_CALLABLE) {
        push_callable(L, value->slot, value->generation); lua_pop(L, 1);
      }
      push_adapter(L, kind == TITAN_BROWSER_HANDLE ? 1 : 2);
      lua_pushinteger(L, value->slot); lua_pushinteger(L, value->generation);
      lua_call(L, 2, 1);
      break;
    default: luaL_error(L, "unsupported browser callback argument kind");
  }
}

static void encode_result(lua_State *L, int index, uint32_t state,
    uint32_t kind, titan_browser_value *value) {
  size_t length;
  int top = lua_gettop(L);
  memset(value, 0, sizeof(*value));
  value->kind = kind;
  switch (kind) {
    case TITAN_BROWSER_NIL:
      if (!lua_isnil(L, index)) luaL_error(L, "browser callback result must be nil");
      break;
    case TITAN_BROWSER_BOOLEAN:
      if (lua_type(L, index) != LUA_TBOOLEAN) luaL_error(L, "browser callback result must be boolean");
      value->scalar.integer = lua_toboolean(L, index); break;
    case TITAN_BROWSER_INTEGER:
      if (!lua_isinteger(L, index)) luaL_error(L, "browser callback result must be integer");
      value->scalar.integer = lua_tointeger(L, index); break;
    case TITAN_BROWSER_FLOAT:
      if (!ttisfloat(s2v(L->ci->func.p + index))) luaL_error(L, "browser callback result must be float");
      value->scalar.number = lua_tonumber(L, index); break;
    case TITAN_BROWSER_BYTES:
      if (lua_type(L, index) != LUA_TSTRING) luaL_error(L, "browser callback result must be bytes");
      value->bytes = (const unsigned char *)lua_tolstring(L, index, &length);
      value->length = (uint32_t)length; break;
    case TITAN_BROWSER_HANDLE:
    case TITAN_BROWSER_CALLABLE:
      push_adapter(L, kind == TITAN_BROWSER_HANDLE ? 3 : 4);
      lua_pushvalue(L, index); lua_call(L, 1, 2);
      value->state = state;
      value->slot = (uint32_t)luaL_checkinteger(L, -2);
      value->generation = (uint32_t)luaL_checkinteger(L, -1);
      if (!value->slot || !value->generation) luaL_error(L, "browser callback returned a released owner");
      lua_settop(L, top);
      break;
    default: luaL_error(L, "unsupported browser callback result kind");
  }
}

/* No allocating conversion follows these passes. Physical lookup uses only
 * the already reserved stack; the host query cannot call Lua or user code. */
static void validate_identities(lua_State *L, uint32_t count,
    const titan_browser_value *values) {
  uint32_t i;
  for (i = 0; i < count; ++i) {
    if (values[i].kind == TITAN_BROWSER_CALLABLE) {
      push_callable(L, values[i].slot, values[i].generation);
      lua_pop(L, 1);
    }
  }
  for (i = 0; i < count; ++i) {
    const titan_browser_value *value = &values[i];
    if ((value->kind == TITAN_BROWSER_HANDLE || value->kind == TITAN_BROWSER_CALLABLE) &&
        !titan_browser_host_identity_live(value->state, value->slot, value->generation, value->kind))
      luaL_error(L, "browser identity is released or belongs to a closed state");
  }
}

typedef struct invoke_context {
  uint64_t id;
  titan_browser_identity identity;
  uint32_t argc;
  const titan_browser_value *args;
} invoke_context;
static int invoke_worker(lua_State *L) {
  invoke_context *context = (invoke_context *)lua_touserdata(L, 1);
  bridge_callable *callable;
  uint32_t i, count;
  titan_browser_value small[8], *results = small;
  titan_browser_completion completion = {0};
  int base;
  lua_settop(L, 0);
  luaL_checkstack(L, 8, "browser callable lookup");
  callable = push_callable(L, context->identity.slot, context->identity.generation);
  count = callable->signature.result_count;
  if (context->argc != callable->signature.parameter_count)
    luaL_error(L, "browser callback argument count mismatch");
  if (context->argc > INT_MAX - 8 || count > INT_MAX - 8)
    luaL_error(L, "browser callback signature is too large");
  luaL_checkstack(L, (int)(context->argc > count ? context->argc : count) + 8, "browser callback values");
  if (count > sizeof(small) / sizeof(small[0]))
    results = (titan_browser_value *)lua_newuserdatauv(L, (size_t)count * sizeof(*results), 0);
  lua_getiuservalue(L, 1, 1); /* the ORIGINAL closure, never its inspected/coerced view */
  for (i = 0; i < context->argc; ++i)
    push_argument(L, context->identity.state, callable->signature.parameters[i], &context->args[i]);
  validate_identities(L, context->argc, context->args);
  base = lua_gettop(L) - (int)context->argc - 1;
  lua_call(L, (int)context->argc, LUA_MULTRET);
  if (lua_gettop(L) - base != (int)count) luaL_error(L, "browser callback result count mismatch");
  for (i = 0; i < count; ++i)
    encode_result(L, base + (int)i + 1, context->identity.state, callable->signature.results[i], &results[i]);
  validate_identities(L, count, results);
  completion.operation_id = context->id;
  completion.operation = TITAN_BROWSER_INVOKE;
  completion.result_count = count;
  completion.results = results;
  flush_completion(&completion); /* all original result owners remain rooted */
  return 0;
}

int titan_browser_invoke(uint64_t id, uint32_t token, uint32_t slot,
    uint32_t generation, uint32_t argc, const titan_browser_value *args) {
  bridge_state *state;
  invoke_context context = {id, {token, slot, generation}, argc, args};
  if (!id || !titan_browser_entry_allowed(id, TITAN_BROWSER_INVOKE)) return -1;
  state = find_state(token);
  if (!state || state->closing || (state->L == owner && !owner_ready))
    return invalid_entry(id, TITAN_BROWSER_INVOKE, "browser state is closed, closing or uninitialized");
  return protected_entry(id, TITAN_BROWSER_INVOKE, state->L, invoke_worker, &context, 0, -1);
}

typedef struct release_context { titan_browser_identity identity; } release_context;
static int release_worker(lua_State *L) {
  release_context *context = (release_context *)lua_touserdata(L, 1);
  titan_browser_drop_callable(L, &context->identity);
  return 0;
}
int titan_browser_release_callable(uint64_t id, uint32_t token, uint32_t slot, uint32_t generation) {
  bridge_state *state;
  release_context context = {{token, slot, generation}};
  if (!id || !titan_browser_entry_allowed(id, TITAN_BROWSER_RELEASE)) return -1;
  state = find_state(token);
  if (!state) return invalid_entry(id, TITAN_BROWSER_RELEASE, "browser state is closed");
  return protected_entry(id, TITAN_BROWSER_RELEASE, state->L, release_worker, &context, 0, 0);
}
