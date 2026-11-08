#ifndef TITAN_COUNTER_H
#define TITAN_COUNTER_H
#include <titan/browser.h>

/* Registers a click callback on the element the selector names, with the
 * pinned handler's identity as its user data; counter_unlisten removes it.
 * Both return html5.h's EMSCRIPTEN_RESULT, 0 on success. */
int counter_listen(const char *selector, const titan_browser_identity *identity);
int counter_unlisten(const char *selector);
#endif
