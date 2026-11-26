#ifndef TITAN_BROWSER_FIXTURE_CONTROLS_H
#define TITAN_BROWSER_FIXTURE_CONTROLS_H
#include <stdint.h>
#include <titan/browser.h>

/* The fixtures' shared host imports. fixture-imports.mjs implements them; a
 * harness passes it to create({imports}), the runner to directly run images.
 *
 * Fault injection and close-order observers are fixture-only JS boundaries. */
TITAN_WASM_IMPORT("gate_test_state_record") void *gate_test_state_record(void *state);
TITAN_WASM_IMPORT("titan_bridge_test_earlier_cleanup") void titan_bridge_test_earlier_cleanup(int index);
TITAN_WASM_IMPORT("gate_test_state_closed") void gate_test_state_closed(uint32_t token);
TITAN_WASM_IMPORT("titan_bridge_test_release_due_gc") int titan_bridge_test_release_due_gc(void);

/* Test-owned controls deliberately go only to an explicit fixture binding;
 * generated images never expose their instance in their public API. */
TITAN_WASM_IMPORT("gate_test_publish") void gate_test_publish(void);

/* A real outer JSPI wait on a host timer. */
TITAN_WASM_IMPORT("fixture_sleep") void fixture_sleep(int milliseconds);
#endif
