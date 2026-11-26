#ifndef TITAN_BROWSER_CLICK_HOST_H
#define TITAN_BROWSER_CLICK_HOST_H
#include <stdbool.h>
#include <titan/browser.h>

/* The page's click registration, a host API of the kind a C library binds
 * (spec/fixtures/browser_runtime/fixture-imports.mjs). A click on the element
 * that `selector` names calls `callback(user_data)` synchronously through the
 * function table; another registration replaces it and a NULL callback
 * removes it. Returns 0, or -1 when no element matches. */
typedef bool (*titan_test_click_callback)(void *user_data);
TITAN_WASM_IMPORT("titan_test_set_click_callback")
int titan_test_set_click_callback(const char *selector, void *user_data,
                                  titan_test_click_callback callback);
#endif
