#ifndef TITAN_BROWSER_H
#define TITAN_BROWSER_H

#include <stddef.h>
#include <stdint.h>
#include <lua.h>
#include <titan/ffi.h>

/* The bridge is an in-process wasm32 ABI, not a serialized message format.
 * All counts and identities are unsigned 32-bit, operation ids unsigned 64-bit.
 * Zero is never a live state, slot, generation or operation id. */
enum titan_browser_kind {
  TITAN_BROWSER_NIL = 0,
  TITAN_BROWSER_BOOLEAN = 1,
  TITAN_BROWSER_INTEGER = 2,
  TITAN_BROWSER_FLOAT = 3,
  TITAN_BROWSER_BYTES = 4,
  TITAN_BROWSER_HANDLE = 5,
  TITAN_BROWSER_CALLABLE = 6,
  TITAN_BROWSER_VOID = 7,
  TITAN_BROWSER_REQUEST = 8
};
enum titan_browser_status {
  TITAN_BROWSER_OK = 0,
  TITAN_BROWSER_TITAN_ERROR = 1,
  TITAN_BROWSER_JS_ERROR = 2,
  TITAN_BROWSER_STATE = 3,
  TITAN_BROWSER_SIGNATURE = 4,
  TITAN_BROWSER_MEMORY = 5
};
enum titan_browser_operation {
  TITAN_BROWSER_INITIALIZE = 1,
  TITAN_BROWSER_MAIN = 2,
  TITAN_BROWSER_INVOKE = 3,
  TITAN_BROWSER_RELEASE = 4,
  TITAN_BROWSER_CLOSE = 5
};
enum titan_browser_stream {
  TITAN_BROWSER_STDOUT = 1,
  TITAN_BROWSER_STDERR = 2
};
enum titan_browser_request_mode {
  TITAN_BROWSER_START = 0,
  TITAN_BROWSER_LISTEN = 1
};

typedef union titan_browser_scalar {
  int64_t integer;
  double number;
} titan_browser_scalar;
typedef struct titan_browser_value {
  uint32_t kind;
  uint32_t state;
  /* For BYTES results scalar.integer is the allocated byte capacity. */
  titan_browser_scalar scalar;
  const unsigned char *bytes;
  uint32_t length;
  uint32_t slot;
  uint32_t generation;
} titan_browser_value;
typedef struct titan_browser_identity {
  uint32_t state;
  uint32_t slot;
  uint32_t generation;
} titan_browser_identity;
typedef struct titan_browser_signature {
  uint32_t parameter_count;
  uint32_t result_count;
  const uint32_t *parameters;
  const uint32_t *results;
} titan_browser_signature;

/* Imports fill a zero-initialized response and always return normally.
 * status is independent of value kind; state is filled on every status.
 * thrown_slot/generation own the exact thrown JS value, even undefined/null/
 * false. The caller clears adopted slots; dispose releases remaining units.
 * Nonempty message and BYTES result
 * buffers are malloc-owned; dispose frees them even on a failed import.
 * JS must use current memory views after allocating. Capacity is validated
 * before copying and length is the exact returned byte count, not capacity. */
typedef struct titan_browser_response {
  uint32_t status;
  uint32_t state;
  titan_browser_value value;
  const unsigned char *message;
  uint32_t message_length;
  uint32_t thrown_slot;
  uint32_t thrown_generation;
} titan_browser_response;

/* complete copies all arrays, bytes and trace synchronously. Export promise
 * fulfillment means physical retirement only; this is the application result.
 * Each admitted entry emits exactly one record with its supplied id and kind. */
typedef struct titan_browser_completion {
  uint64_t operation_id;
  uint32_t operation;
  uint32_t status;
  int32_t application_status;
  uint32_t result_count;
  const titan_browser_value *results;
  const unsigned char *message;
  uint32_t message_length;
  const unsigned char *trace;
  uint32_t trace_length;
} titan_browser_completion;

#if defined(__EMSCRIPTEN__)
_Static_assert(sizeof(void *) == 4, "browser bridge requires wasm32");
_Static_assert(sizeof(titan_browser_scalar) == 8, "browser scalar layout");
_Static_assert(sizeof(titan_browser_value) == 32, "browser value layout");
_Static_assert(offsetof(titan_browser_value, state) == 4, "browser state offset");
_Static_assert(offsetof(titan_browser_value, scalar) == 8, "browser scalar offset");
_Static_assert(offsetof(titan_browser_value, bytes) == 16, "browser bytes offset");
_Static_assert(offsetof(titan_browser_value, length) == 20, "browser length offset");
_Static_assert(offsetof(titan_browser_value, slot) == 24, "browser slot offset");
_Static_assert(offsetof(titan_browser_value, generation) == 28, "browser generation offset");
_Static_assert(sizeof(titan_browser_identity) == 12, "browser identity layout");
_Static_assert(sizeof(titan_browser_signature) == 16, "browser signature layout");
_Static_assert(offsetof(titan_browser_signature, parameters) == 8, "browser parameters offset");
_Static_assert(offsetof(titan_browser_signature, results) == 12, "browser results offset");
_Static_assert(sizeof(titan_browser_response) == 56, "browser response layout");
_Static_assert(offsetof(titan_browser_response, state) == 4, "browser response state offset");
_Static_assert(offsetof(titan_browser_response, value) == 8, "browser response value offset");
_Static_assert(offsetof(titan_browser_response, message) == 40, "browser response message offset");
_Static_assert(offsetof(titan_browser_response, message_length) == 44, "browser response message length offset");
_Static_assert(offsetof(titan_browser_response, thrown_slot) == 48, "browser response thrown offset");
_Static_assert(offsetof(titan_browser_response, thrown_generation) == 52, "browser response thrown generation offset");
_Static_assert(sizeof(titan_browser_completion) == 48, "browser completion layout");
_Static_assert(offsetof(titan_browser_completion, operation) == 8, "browser completion operation offset");
_Static_assert(offsetof(titan_browser_completion, status) == 12, "browser completion status offset");
_Static_assert(offsetof(titan_browser_completion, application_status) == 16, "browser completion app status offset");
_Static_assert(offsetof(titan_browser_completion, result_count) == 20, "browser completion count offset");
_Static_assert(offsetof(titan_browser_completion, results) == 24, "browser completion results offset");
_Static_assert(offsetof(titan_browser_completion, message) == 28, "browser completion message offset");
_Static_assert(offsetof(titan_browser_completion, message_length) == 32, "browser completion length offset");
_Static_assert(offsetof(titan_browser_completion, trace) == 36, "browser completion trace offset");
_Static_assert(offsetof(titan_browser_completion, trace_length) == 40, "browser completion trace length offset");
#endif

/* Stateful promised exports. Only alloc/free and the backend stack metadata
 * helpers bypass the JSPI owner. The private engine entry is not a gateway. */
int titan_browser_initialize(uint64_t operation_id);
int titan_browser_entry(uint64_t operation_id, int argc,
    const unsigned char *const *argv, const size_t *lengths);
int titan_browser_invoke(uint64_t operation_id, uint32_t state, uint32_t slot,
    uint32_t generation, uint32_t argc, const titan_browser_value *args);
int titan_browser_release_callable(uint64_t operation_id, uint32_t state,
    uint32_t slot, uint32_t generation);
int titan_browser_close(uint64_t operation_id);
void *titan_browser_alloc(size_t length);
void titan_browser_free(void *buffer);

/* Runtime construction precedes luaL_openlibs and any user/module initializer.
 * attach runs inside the caller's protected bootstrap. close_state is an
 * owner-held lua_close, never a pcall on the state being freed. Detach alone
 * does not call it. Closing is detected for direct lua_close paths as well. */
uint32_t titan_browser_attach(lua_State *L);
uint32_t titan_browser_state(lua_State *L);
int titan_browser_state_closing(lua_State *L);
void titan_browser_close_state(lua_State *L);
void titan_browser_configure(lua_State *L, TValue handle_factory,
    TValue callable_factory, TValue handle_identity, TValue callable_identity);
void titan_browser_root_callable(lua_State *L, TValue original,
    const titan_browser_signature *signature, titan_browser_identity *out);
void titan_browser_drop_callable(lua_State *L, const titan_browser_identity *identity);
void titan_browser_response_dispose(titan_browser_response *response);

/* Generated-image bootstrap collaborators, not additional exported gateways. */
int titan_browser_initialize_image(uint64_t operation_id, lua_CFunction initialize,
    const char *program_name, int state_status);
int titan_browser_main_image(uint64_t operation_id, lua_CFunction main,
    void *arguments);
int titan_browser_close_image(uint64_t operation_id);

/* JS imports. All host_* potentially throwing boundaries catch at the import
 * and fill response; C/Titan raises only after their normal return. Trusted
 * state/metadata/release imports are nonthrowing and never enter Lua or sinks.
 * Every JS slot unit is charged to state, including allocations during close. */
int titan_browser_entry_allowed(uint64_t operation_id, uint32_t operation);
void titan_browser_complete(const titan_browser_completion *completion);
uint32_t titan_browser_host_state_open(void);
void titan_browser_host_state_closing(uint32_t state);
void titan_browser_host_state_closed(uint32_t state);
void titan_browser_host_callable(uint32_t state, uint32_t slot,
    uint32_t generation, const titan_browser_signature *signature);
void titan_browser_host_callable_closed(uint32_t state, uint32_t slot,
    uint32_t generation);
void titan_browser_host_release(uint32_t state, uint32_t slot, uint32_t generation);
/* Transfer a marshaling temporary to its fully constructed Titan owner. */
void titan_browser_host_adopt(uint32_t state, uint32_t slot, uint32_t generation);
/* Pure logical liveness: ordinary stale data returns false, never poisons.
 * No Lua, user callback or sink can run between final validation and copying. */
int titan_browser_host_identity_live(uint32_t state, uint32_t slot,
    uint32_t generation, uint32_t kind);
void titan_browser_host_binding(uint32_t state, const unsigned char *name,
    uint32_t length, titan_browser_response *response);
void titan_browser_host_call(uint32_t state, uint32_t slot, uint32_t generation,
    uint32_t argc, const titan_browser_value *args, uint32_t result_kind,
    titan_browser_response *response);
void titan_browser_host_start(uint32_t state, uint32_t slot, uint32_t generation,
    uint32_t argc, const titan_browser_value *args, uint32_t completion_slot,
    uint32_t completion_generation, uint32_t failure_slot,
    uint32_t failure_generation, uint32_t mode, titan_browser_response *response);
void titan_browser_host_cancel(uint32_t state, uint32_t slot, uint32_t generation,
    titan_browser_response *response);

/* SDK byte I/O admissions. completion_slot==0 appends output synchronously
 * (including close-phase output); otherwise the exact callable is notified
 * with zero arguments on success. Reads notify a one-BYTES-parameter callable.
 * Both require a failure callable with exact (BYTES, HANDLE) -> () signature;
 * host rejection is a queued terminal notification, not a callback error.
 * Imports do not await a sink/source and return a REQUEST owner. */
void titan_browser_host_write(uint32_t state, uint32_t stream,
    const unsigned char *bytes, uint32_t length, uint32_t completion_slot,
    uint32_t completion_generation, uint32_t failure_slot,
    uint32_t failure_generation, titan_browser_response *response);
void titan_browser_host_read(uint32_t state, uint32_t capacity,
    uint32_t completion_slot, uint32_t completion_generation,
    uint32_t failure_slot, uint32_t failure_generation,
    titan_browser_response *response);

#endif
