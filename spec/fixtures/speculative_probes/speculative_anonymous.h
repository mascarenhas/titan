#ifndef TITAN_SPECULATIVE_ANONYMOUS_H
#define TITAN_SPECULATIVE_ANONYMOUS_H

#include "speculative.h"

/* A probe converting this pointer cannot render its anonymous pointee. */
static struct { int value; } *spec_anonymous_first(void) { return 0; }

#endif
