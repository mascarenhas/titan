#ifndef TITAN_COUNTER_H
#define TITAN_COUNTER_H
#include <emscripten/html5.h>

/* The C callback needs a zero-initialized automatic result aggregate, which
 * restricted foreign bodies cannot declare. Titan registers it directly. */
bool counter_click(int type, const EmscriptenMouseEvent *event, void *identity);
#endif
