#include <titan/browser.h>
#include <stdio.h>
#include <stdlib.h>
#include "counter.h"

/* Keep this test-only callback in C: its zero-initialized automatic result
 * aggregate cannot be declared in a restricted foreign-function body.
 * The pinned handler returns nil, so only a failure's message and trace
 * need freeing. Registration and unregistration live in Titan. */
bool counter_click(int type, const EmscriptenMouseEvent *event, void *identity) {
  (void)type;
  (void)event;
  titan_browser_sync_result result = {0};
  if (titan_browser_call_sync(identity, 0, NULL, &result) != TITAN_BROWSER_OK && result.message)
    fprintf(stderr, "click handler failed: %.*s\n", (int)result.message_length, (const char *)result.message);
  free((void *)result.message);
  free((void *)result.trace);
  return false;
}
