#ifndef TITAN_WEBSOCKET_BROWSER_TEST_NATIVE_H
#define TITAN_WEBSOCKET_BROWSER_TEST_NATIVE_H
#include <titan/browser.h>
/* The live network harness's controls, published by the fixture host import
 * (spec/fixtures/browser_runtime/fixture-imports.mjs). */
TITAN_WASM_IMPORT("titan_net_test_publish") void titan_net_test_publish(void);
#endif
