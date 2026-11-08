#include <emscripten/html5.h>
#include <stdio.h>
#include <stdlib.h>
#include "counter.h"

/* The html5 click callback: one synchronous call of the pinned handler whose
 * identity is the user data. The handler returns nil, so only a failure's
 * message and trace need freeing. */
static bool counter_click(int type, const EmscriptenMouseEvent *event, void *identity) {
  (void)type;
  (void)event;
  titan_browser_sync_result result = {0};
  if (titan_browser_call_sync(identity, 0, NULL, &result) != TITAN_BROWSER_OK && result.message)
    fprintf(stderr, "click handler failed: %.*s\n", (int)result.message_length, (const char *)result.message);
  free((void *)result.message);
  free((void *)result.trace);
  return false;
}

int counter_listen(const char *selector, const titan_browser_identity *identity) {
  return emscripten_set_click_callback(selector, (void *)identity, false, counter_click);
}

int counter_unlisten(const char *selector) {
  return emscripten_set_click_callback(selector, NULL, false, NULL);
}
