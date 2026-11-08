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
  TITAN_BROWSER_STRING = 4,
  TITAN_BROWSER_BYTES = 5,
  TITAN_BROWSER_HANDLE = 6,
  TITAN_BROWSER_CALLABLE = 7,
  TITAN_BROWSER_REQUEST = 8
};
enum titan_browser_status {
  TITAN_BROWSER_OK = 0,
  TITAN_BROWSER_TITAN_ERROR = 1,
  TITAN_BROWSER_JS_ERROR = 2,
  TITAN_BROWSER_STATE = 3,
  TITAN_BROWSER_MEMORY = 4
};
enum titan_browser_operation {
  TITAN_BROWSER_INITIALIZE = 1,
  TITAN_BROWSER_MAIN = 2,
  TITAN_BROWSER_INVOKE = 3,
  TITAN_BROWSER_RELEASE = 4,
  TITAN_BROWSER_CLOSE = 5
};
enum titan_browser_request_mode {
  TITAN_BROWSER_START = 0,
  TITAN_BROWSER_LISTEN = 1
};
enum titan_browser_relinquish_mode {
  TITAN_BROWSER_TURN = 0,
  TITAN_BROWSER_WAIT = 1
};
/* A wait with no wake source returns IDLE without suspending. The first
 * relinquish after dispose() began resolves DISPOSING once; afterwards every
 * resumed relinquish reports DISPOSING instead of RESUMED. */
enum titan_browser_relinquish_status {
  TITAN_BROWSER_RESUMED = 0,
  TITAN_BROWSER_IDLE = 1,
  TITAN_BROWSER_DISPOSING = 2
};
enum titan_browser_delivery_kind {
  TITAN_BROWSER_DELIVER_NONE = 0,
  TITAN_BROWSER_DELIVER_NOTIFY = 1,
  TITAN_BROWSER_DELIVER_CALL = 2,
  TITAN_BROWSER_DELIVER_RELEASE = 3
};

typedef union titan_browser_scalar {
  int64_t integer;
  double number;
} titan_browser_scalar;
typedef struct titan_browser_value {
  uint32_t kind;
  uint32_t state;
  /* For STRING and BYTES results scalar.integer is the allocated byte capacity. */
  titan_browser_scalar scalar;
  const unsigned char *bytes;
  uint32_t length;
  uint32_t slot;
  uint32_t generation;
} titan_browser_value;

/* Imports fill a zero-initialized response and always return normally.
 * status is independent of value kind; state is filled on every status.
 * thrown_slot/generation own the exact thrown JS value, even undefined/null/
 * false. The caller clears adopted slots; dispose releases remaining units.
 * Nonempty message and STRING/BYTES result
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

/* One host item that deliver() runs inside a drive, or one deferred physical
 * release. id names the item for item_done and settle; args stay host-owned
 * until titan_browser_host_item_done. wrapper is the RELEASE kind's flag:
 * 1 for a wrapper release, 0 for a request-hold drop. */
typedef struct titan_browser_delivery {
  uint64_t id;
  uint32_t kind;
  uint32_t slot;
  uint32_t generation;
  uint32_t argc;
  const titan_browser_value *args;
  uint32_t wrapper;
} titan_browser_delivery;

/* A pinned callable's identity, which C keeps as callback user data. Copy it
 * from BrowserPin:identity(); a stale identity is refused by generation. */
typedef struct titan_browser_identity {
  uint32_t state;
  uint32_t slot;
  uint32_t generation;
} titan_browser_identity;

/* The caller zero-initializes the result. After any status it frees message,
 * trace and a STRING/BYTES value's bytes, all malloc-owned when present. A
 * HANDLE value stays valid while its Titan BrowserHandle is open, a CALLABLE
 * one while a BrowserPin or a live JavaScript wrapper holds the function.
 * MEMORY, which also reports a result, message, trace or refusal copy that
 * could not be allocated, carries no message, trace or value. */
typedef struct titan_browser_sync_result {
  uint32_t status;
  uint32_t reserved;
  titan_browser_value value;
  const unsigned char *message;
  uint32_t message_length;
  const unsigned char *trace;
  uint32_t trace_length;
} titan_browser_sync_result;

/* titan_browser_callback_enter fills L, the callback thread to run on, and
 * depth; titan_browser_callback_leave takes the same frame back. */
typedef struct titan_browser_callback_frame {
  lua_State *L;
  uint32_t state;
  uint32_t depth;
} titan_browser_callback_frame;

typedef struct titan_browser_state_record {
  lua_State *L;
  uint32_t token;
  int closing;
  int configured;
  TValue invoke_handler;
  TValue release_handler;
  titan_browser_completion *fallback;
  /* Synchronous C callbacks: entries like invoke_handler, the thread the next
   * callback level runs on (NULL while it is being prepared), and the depth. */
  TValue callback_handler;
  TValue call_sync_handler;
  lua_State *callback_next;
  uint32_t callback_depth;
} titan_browser_state_record;

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
_Static_assert(sizeof(titan_browser_delivery) == 32, "browser delivery layout");
_Static_assert(offsetof(titan_browser_delivery, kind) == 8, "browser delivery kind offset");
_Static_assert(offsetof(titan_browser_delivery, slot) == 12, "browser delivery slot offset");
_Static_assert(offsetof(titan_browser_delivery, generation) == 16, "browser delivery generation offset");
_Static_assert(offsetof(titan_browser_delivery, argc) == 20, "browser delivery count offset");
_Static_assert(offsetof(titan_browser_delivery, args) == 24, "browser delivery arguments offset");
_Static_assert(offsetof(titan_browser_delivery, wrapper) == 28, "browser delivery wrapper offset");
_Static_assert(sizeof(titan_browser_identity) == 12, "browser identity layout");
_Static_assert(offsetof(titan_browser_identity, slot) == 4, "browser identity slot offset");
_Static_assert(offsetof(titan_browser_identity, generation) == 8, "browser identity generation offset");
_Static_assert(sizeof(titan_browser_sync_result) == 56, "browser sync result layout");
_Static_assert(offsetof(titan_browser_sync_result, value) == 8, "browser sync result value offset");
_Static_assert(offsetof(titan_browser_sync_result, message) == 40, "browser sync result message offset");
_Static_assert(offsetof(titan_browser_sync_result, message_length) == 44, "browser sync result length offset");
_Static_assert(offsetof(titan_browser_sync_result, trace) == 48, "browser sync result trace offset");
_Static_assert(offsetof(titan_browser_sync_result, trace_length) == 52, "browser sync result trace length offset");
_Static_assert(sizeof(titan_browser_callback_frame) == 12, "browser callback frame layout");
_Static_assert(offsetof(titan_browser_callback_frame, state) == 4, "browser callback frame state offset");
_Static_assert(offsetof(titan_browser_callback_frame, depth) == 8, "browser callback frame depth offset");
#endif

/* Stateful promised exports. Only _malloc/_free and the backend stack metadata
 * helpers bypass the JSPI owner. The private engine entry is not a gateway. */
int titan_browser_initialize(uint64_t operation_id);
int titan_browser_entry(uint64_t operation_id, int argc,
    const unsigned char *const *argv, const size_t *lengths);
int titan_browser_invoke(uint64_t operation_id, uint32_t state, uint32_t slot,
    uint32_t generation, uint32_t argc, const titan_browser_value *args);
int titan_browser_release_callable(uint64_t operation_id, uint32_t state,
    uint32_t slot, uint32_t generation, uint32_t wrapper);
int titan_browser_close(uint64_t operation_id);
int titan_browser_invalid_entry(uint64_t operation_id, uint32_t operation,
    const char *message);
/* Generated launcher: the owner state's main thread. It is set before any
 * module initializer runs and cleared before lua_close. */
lua_State *titan_browser_owner_thread(void);

/* JS imports. All host_* potentially throwing boundaries catch at the import
 * and fill response; C/Titan raises only after their normal return. Trusted
 * state/metadata/release imports are nonthrowing and never enter Lua or sinks.
 * Every JS slot unit is charged to state, including allocations during close. */
int titan_browser_entry_allowed(uint64_t operation_id, uint32_t operation);
void titan_browser_complete(const titan_browser_completion *completion);
uint32_t titan_browser_host_state_open(titan_browser_state_record *record);
titan_browser_state_record *titan_browser_host_state_record(uint32_t state);
void titan_browser_host_state_closing(uint32_t state);
void titan_browser_host_state_closed(uint32_t state);
int titan_browser_host_callable(uint32_t state, uint32_t slot,
    uint32_t generation);
int titan_browser_host_callable_closed(uint32_t state, uint32_t slot,
    uint32_t generation);
void titan_browser_host_release(uint32_t state, uint32_t slot, uint32_t generation);
/* Transfer a marshaling temporary to its fully constructed Titan owner. */
void titan_browser_host_adopt(uint32_t state, uint32_t slot, uint32_t generation);
/* One more unit of a live value slot, for a Titan owner of a borrowed slot (a
 * call_sync HANDLE argument): its close releases only its own unit. */
void titan_browser_host_retain(uint32_t state, uint32_t slot, uint32_t generation);
/* Pure logical liveness: ordinary stale data returns false, never poisons.
 * No Lua, user callback or sink can run between final validation and copying. */
int titan_browser_host_identity_live(uint32_t state, uint32_t slot,
    uint32_t generation, uint32_t kind);
void titan_browser_host_binding(uint32_t state, const unsigned char *name,
    uint32_t length, titan_browser_response *response);
void titan_browser_host_call(uint32_t state, uint32_t slot, uint32_t generation,
    uint32_t argc, const titan_browser_value *args,
    titan_browser_response *response);
void titan_browser_host_start(uint32_t state, uint32_t slot, uint32_t generation,
    uint32_t argc, const titan_browser_value *args, uint32_t completion_slot,
    uint32_t completion_generation, uint32_t failure_slot,
    uint32_t failure_generation, uint32_t mode, titan_browser_response *response);
void titan_browser_host_cancel(uint32_t state, uint32_t slot, uint32_t generation,
    titan_browser_response *response);

/* Driver imports. titan_browser_relinquish is the bridge's only suspending
 * import: it returns a titan_browser_relinquish_status after one turn-source
 * macrotask (TURN), or after a wake (WAIT); a WAIT with no wake source returns
 * IDLE at once. The others are trusted and nonthrowing. host_item marshals
 * arguments into host allocations; it reports a marshalling failure (a
 * callback error or a call rejection), skips that item, and returns 0 once the
 * batch is exhausted. host_settle receives the delivered item's completion. */
uint32_t titan_browser_relinquish(uint32_t state, uint32_t mode);
void titan_browser_host_owner(uint32_t state);
void titan_browser_host_drive_begin(uint32_t state);
void titan_browser_host_drive_end(uint32_t state, int32_t exit_status, uint32_t exited);
/* The async bootstrap's main Task failed: run() resolves failed, status 1,
 * with this message and raw trace, unless the entry failed or a drive latched
 * an exit. The loader copies the bytes; it marks only a pending run entry. */
void titan_browser_host_main_failed(uint32_t state, const char *message, size_t message_len,
    const char *trace, size_t trace_len);
void titan_browser_host_wake(uint32_t state);
uint32_t titan_browser_host_batch(uint32_t state);
int titan_browser_host_item(uint32_t state, titan_browser_delivery *out);
void titan_browser_host_item_done(uint32_t state, uint64_t id);
int titan_browser_host_release_next(uint32_t state, titan_browser_delivery *out);
void titan_browser_host_settle(const titan_browser_completion *record);

/* Synchronous C callbacks. host_hold counts open BrowserPins per state (a
 * wake source for the owner's drive). host_callback(state, 1) admits a
 * callback unless the instance is closing, exited or poisoned and returns 0
 * when it refuses; host_callback(state, -1) ends it. Both are trusted. */
void titan_browser_host_hold(uint32_t state, int32_t delta);
int titan_browser_host_callback(uint32_t state, int32_t delta);

/* Generated forwards to titan.browser's public foreign functions, for C in the
 * image (not JavaScript exports). call_sync runs a pinned callable on a
 * callback thread and returns the result status; it refuses with STATE
 * without entering Lua when the state is closed or closing, the instance is
 * disposing, exited or poisoned, or no callback thread can be prepared. Its
 * HANDLE arguments are borrowed: C keeps each slot it passes, and the
 * callable receives its own reference, whose close or collection never
 * retires C's slot. callback_enter/callback_leave bracket a hand-written
 * trampoline that runs on frame->L. Without titan.browser, call_sync and
 * enter return STATE. */
int titan_browser_call_sync(const titan_browser_identity *callable, uint32_t argc,
    const titan_browser_value *args, titan_browser_sync_result *result);
int titan_browser_callback_enter(uint32_t state, titan_browser_callback_frame *frame);
void titan_browser_callback_leave(titan_browser_callback_frame *frame);

#endif
